# Host Worker Evaluation

This document records the current host-side Template Haskell evaluation
prototype.

## Current Approach

The worker evaluates expression splices by loading the source module in a native
GHC session.

Flow:

```text
worker receives expression splice request
  -> run native GHC 9.8.4
  -> install host-only runMetaHook
  -> load request.sourceFile
  -> defaultRunMeta executes TH normally
  -> hook captures generated LHsExpr GhcPs
  -> worker pretty-prints the captured expansion
  -> worker returns generatedHaskell over JSON Lines
```

This replaces the earlier Task 7 isolated `runghc` splice-eval file. The old
approach proved the process boundary, but it did not have module context and
could not support `reify`.

## Hook Shape

The host worker hook wraps the previous hook or `defaultRunMeta`:

```haskell
captureMetaHook :: IORef [CapturedExpression] -> Maybe (MetaHook TcM) -> MetaHook TcM
captureMetaHook captures previous request spliceExpr =
  case request of
    MetaE wrap -> do
      expanded <- metaRequestE selectedHook spliceExpr
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

The MVP matches a captured expression splice by:

```text
module name
source span
```

The request still carries the pretty-printed splice expression, but the current
selector does not require expression text equality. Task 11 should replace this
with a stable splice key.

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

## Current Limitations

Still unsupported:

- persistent worker sessions;
- whole-module expansion caching;
- declaration, type, and pattern splices over the worker protocol;
- target-only modules/imports;
- target-like CPP/package configuration;
- `Q` side-effect replay;
- stable splice keys.

The cross-side plugin still delegates non-expression splices to local
`defaultRunMeta`. That is acceptable for the current expression-only Task 9
prototype but is not acceptable for real cross compilation.

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
