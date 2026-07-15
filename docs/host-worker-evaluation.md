# Host Worker Evaluation

This document records the current host-side Template Haskell evaluation
prototype.

## Current Approach

The worker evaluates expression and declaration splices by loading the source
module in a native GHC session.

Flow:

```text
worker receives expression/declaration splice request
  -> run native GHC 9.8.4
  -> install host-only runMetaHook
  -> load request.sourceFile
  -> defaultRunMeta executes TH normally
  -> hook captures generated GhcPs expansion
  -> worker pretty-prints the captured expansion
  -> worker returns generatedHaskell over JSON Lines
```

This replaces the earlier Task 7 isolated `runghc` splice-eval file. The old
approach proved the process boundary, but it did not have module context and
could not support `reify`.

## Hook Shape

The host worker hook wraps the previous hook or `defaultRunMeta`:

```haskell
captureMetaHook :: IORef [CapturedSplice] -> Maybe (MetaHook TcM) -> MetaHook TcM
captureMetaHook captures previous request spliceExpr =
  case request of
    MetaE wrap -> do
      expanded <- metaRequestE selectedHook spliceExpr
      record spliceExpr expanded
      pure (wrap expanded)
    MetaD wrap -> do
      expanded <- metaRequestD selectedHook spliceExpr
      record spliceExpr expanded
      pure (wrap expanded)
    _ ->
      selectedHook request spliceExpr
  where
    selectedHook = fromMaybe defaultRunMeta previous
```

The host GHC session must not install the cross-side delegating hook. It should
run normal Template Haskell locally on the build host.

## Matching

The worker matches a captured splice by:

```text
spliceKey
```

The key is derived from:

```text
module name
splice kind
source span
```

The worker must load the same source view as the cross-side compiler. A key
mismatch means the worker did not capture the requested source occurrence.

## Supported Case

Simple expression splice:

```haskell
foo :: Int
foo = $([| 42 |])
```

Module-aware `reify`:

```haskell
{-# LANGUAGE TemplateHaskell #-}

module ReifyExpr where

import Language.Haskell.TH (reify)

data User = User String

$(pure [])

foo :: Int
foo =
  $( do
       _ <- reify ''User
       [| 42 |]
   )
```

The top-level `$(pure [])` is needed to split declaration groups so normal GHC
staging makes `User` visible to `reify`.

Declaration-group ordering with generated declarations:

```haskell
{-# LANGUAGE TemplateHaskell #-}

module DeclOrder where

import DeclOrderGen (genUser)
import Language.Haskell.TH (reify)

$(genUser)

$(pure [])

foo :: Int
foo =
  $( do
       _ <- reify ''GeneratedUser
       [| 42 |]
   )
```

Here `genUser` is imported from another module to satisfy normal GHC stage
restrictions. The first declaration splice generates `GeneratedUser`; the empty
declaration splice closes the declaration group; the later expression splice can
then `reify ''GeneratedUser`.

## Current Limitations

Still unsupported:

- target-only modules/imports;
- target-like CPP/package configuration;
- complete `Q` side-effect replay;

Target context limitations are detailed in `docs/target-context.md`.

The cross-side plugin now routes expression, type, pattern, and declaration
splices through the worker in worker mode. Annotation-wrapper requests are used
internally for same-GHC-version annotation replay.

## Operational Notes

The worker calls:

```text
ghc --print-libdir
```

and passes that path to `runGhc`. Without this, an executable launched from
`dist-newstyle` can make `runGhc Nothing` look for `lib/settings` relative to
the worker binary.

The worker also enables `Opt_ForceRecomp` in the native GHC session so cached
`.hi`/`.o` files do not bypass TH execution and leave the capture list empty.

The worker adds the requested source file directory to the native GHC session's
`importPaths`. This lets module-aware evaluation find sibling generator modules
used by test files.

Generated declarations are pretty-printed with `sdocSuppressUniques = True`.
Without this, GHC can print names like `GeneratedUser_a2aU`, which are valid
debug output but wrong as textual Haskell returned to the cross-side parser.
