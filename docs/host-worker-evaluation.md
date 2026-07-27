# Host Worker Evaluation

This document records the current host-side Template Haskell evaluation
prototype.

## Current Approach

The worker evaluates Template Haskell splices by loading the source module in a
native patched GHC session.

Flow:

```text
worker receives splice request
  -> run native patched GHC 9.10.3
  -> install host-only runMetaHook
  -> load request.sourceFile
  -> runMeta' executes TH normally
  -> hook captures raw TH.Exp/TH.Pat/TH.Type/[TH.Dec]
  -> worker converts the raw payload back to GhcPs for native compilation
  -> worker returns raw TH AST over the binary-framed protocol
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

Still unsupported or intentionally limited:

- target-only modules/imports;
- complete Cabal component context derivation outside the explicit host package
  id/source dir/GHC option forwarding used by the current Nix experiments;
- complete `Q` side-effect replay;
- cross-version worker/consumer pairs.

Target context handling is detailed in `docs/target-context.md`. Modules that
native GHC cannot load at all are covered by `docs/target-only-modules.md`.

The cross-side plugin now routes expression, type, pattern, and declaration
splices through the worker in worker mode. Annotation-wrapper requests are used
internally for annotation replay. They are same-version binary payloads, not a
stable cross-version format.

## Operational Notes

The worker calls:

```text
ghc --print-libdir
```

and passes that path to `runGhc`. Packaged environments can override this with:

```text
TH_HOST_GHC_LIBDIR=/path/to/host/ghc/libdir
```

The override is important when the worker runs inside a different consumer GHC
environment. The worker is built with the patched native GHC 9.10.3 used for
raw TH capture; discovering `ghc` from `PATH` could find an unrelated compiler
libdir.

Without an explicit libdir, an executable launched from `dist-newstyle` can also
make `runGhc Nothing` look for `lib/settings` relative to the worker binary.

The worker also enables `Opt_ForceRecomp` in the native GHC session so cached
`.hi`/`.o` files do not bypass TH execution and leave the capture list empty.

The worker adds the requested source file directory to the native GHC session's
`importPaths`. This lets module-aware evaluation find sibling generator modules
used by test files.

## Why Not Textual Rendering

The previous prototype serialized splice results by pretty-printing generated
GHC AST as Haskell source and reparsing it on the consumer side. That path is
now legacy.

Textual rendering was useful as an early process-boundary proof, but it is not a
complete representation of Template Haskell results:

- pretty-printed GHC AST is diagnostic output, not a guaranteed parser
  round-trip format;
- generated code can refer to exact `TH.Name`s that cannot be reconstructed
  from source text;
- real packages such as `aeson` can generate references whose constructors or
  helpers live in internal/non-exported modules, so the consumer module cannot
  legally name them in textual Haskell.

The active worker therefore captures raw `TH.Exp`, `TH.Pat`, `TH.Type`, and
`[TH.Dec]` values after `runMeta'` executes the host-side `Q` action. It returns
those values through the binary protocol and converts the same values locally so
native compilation can continue.

## `addTopDecls`

`addTopDecls` is also raw-only. The GHC patch records the original `[TH.Dec]`
argument supplied to `qAddTopDecls` in addition to GHC's normal converted
top-level declarations. The worker returns that raw list in `addedTopDecls`, and
the cross-side plugin converts it with `convertToHsDecls`.

For non-declaration splices, the cross-side plugin also mirrors the relevant
`tcg_th_topnames` update for exact binders. This preserves relationships such as
a declaration added through `addTopDecls` being referenced by an exact
`newName`-generated name in the normal splice result.
