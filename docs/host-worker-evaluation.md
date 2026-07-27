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

Still unsupported:

- target-only modules/imports;
- target-like CPP/package configuration;
- complete `Q` side-effect replay;

Target context limitations are detailed in `docs/target-context.md`. Modules
that native GHC cannot load at all are covered by
`docs/target-only-modules.md`.

The cross-side plugin now routes expression, type, pattern, and declaration
splices through the worker in worker mode. Annotation-wrapper requests are used
internally for annotation replay; cross-version compatibility is conditional and
covered by the explicit probes in `docs/cross-version.md`.

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
environment. For example, a worker built with GHC 9.8.4 may be launched while
the consumer package is being built with GHC 9.10.3. In that case discovering
`ghc` from `PATH` would find the wrong compiler libdir.

Without an explicit libdir, an executable launched from `dist-newstyle` can also
make `runGhc Nothing` look for `lib/settings` relative to the worker binary.

The worker also enables `Opt_ForceRecomp` in the native GHC session so cached
`.hi`/`.o` files do not bypass TH execution and leave the capture list empty.

The worker adds the requested source file directory to the native GHC session's
`importPaths`. This lets module-aware evaluation find sibling generator modules
used by test files.

Generated declarations are pretty-printed with `sdocSuppressUniques = True`.
Without this, GHC can print names like `GeneratedUser_a2aU`, which are valid
debug output but wrong as textual Haskell returned to the cross-side parser.

## Declaration Rendering Limitation

The prototype currently serializes generated declarations by applying GHC's
normal `ppr` to `LHsDecl GhcPs` and reparsing the resulting text on the
consumer side.

This is not guaranteed to be parser-roundtrippable. A concrete failing case is
an annotation declaration with a type signature:

```haskell
{-# ANN module (42 :: Int) #-}
```

GHC 9.8.4 can pretty-print the generated declaration as:

```haskell
{-# ANN module 42 :: GHC.Types.Int #-}
```

That text is useful diagnostic output, but it is not accepted by the parser as
a declaration fragment. The parser expects parentheses around the annotated
expression when it contains a type signature.

This affects mixed paths such as:

```text
expression splice
  -> addTopDecls [annotation declaration]
  -> worker pretty-prints added declaration
  -> consumer reparses added declaration
```

It does not invalidate the separate `MetaAW` binary compatibility probe in
`docs/cross-version.md`, because direct source annotations exercise
`MetaAW` without first going through declaration pretty-print/reparse.

### Source-like Printer Investigation

GHC 9.8.4 exposes `GHC.Parser.Annotation`, but does not expose a general
source-like printer that can turn generated `GhcPs` declarations into guaranteed
parser-roundtrippable source.

HLS uses `ghc-exactprint` for source-preserving rewrites, but for generated AST
nodes its annotation path still starts from:

```haskell
render dflags = showSDoc dflags . ppr
```

and then reparses that rendered text to compute exact-print annotations. That
does not solve cases where `ppr` itself is not parser-roundtrippable.

Current decision:

- keep generic declaration rendering as an MVP limitation;
- prefer direct textual splice results for normal declaration splices;
- treat `addTopDecls` declaration replay as best-effort until a more robust
  source renderer or targeted declaration renderer is implemented;
- if needed, handle specific declaration constructors such as `AnnD` with
  targeted source rendering rather than assuming generic `ppr` is source.
