# GHC 9.4.8 Consumer Plugin Investigation

This document records the first check of using GHC 9.4.8 as the consumer/cross
compiler while keeping the host worker on GHC 9.8.4.

## Motivation

Plain nixpkgs does not provide cross GHC 9.8.4 for
`pkgsCross.aarch64-multiplatform`, but it does evaluate cross GHC 9.4.8.

The TH cross architecture does not require the consumer/cross compiler to match
the worker GHC version:

```text
host worker:
  GHC 9.8.4

consumer/cross compiler:
  any supported GHC with a compatible THCross.Plugin

wire format:
  textual Haskell fragments
```

Therefore GHC 9.4.8 is a plausible plain-nixpkgs candidate for validating the
cross side of the protocol.

## Initial Native GHC 9.4.8 Check

Native GHC 9.4.8 from nixpkgs:

```bash
nix build nixpkgs#haskell.compiler.ghc948 --no-link

/nix/store/3amrzixzq1g9m9x88aljidlyfdqra9fr-ghc-9.4.8/bin/ghc --numeric-version
```

Observed:

```text
9.4.8
```

Its installed core packages include:

```text
ghc-9.4.8
base-4.17.2.1
```

## Cabal Bounds

The initial attempt to build the plugin package with GHC 9.4.8 failed before
API checking:

```bash
cabal --store-dir .cabal-store-ghc948 \
  build \
  --project-dir prototype \
  --builddir dist-newstyle-ghc948 \
  --with-compiler /nix/store/3amrzixzq1g9m9x88aljidlyfdqra9fr-ghc-9.4.8/bin/ghc \
  th-cross-plugin
```

Observed failure:

```text
conflict: th-cross-plugin => base>=4.19 && <4.22
installed: base-4.17.2.1
```

The package bounds were then widened for the plugin library:

```text
base >= 4.17 && < 4.22
ghc >= 9.4 && < 9.11
ghc-boot >= 9.4 && < 9.11
```

The host worker remains GHC 9.8.4-only. Only the consumer-side plugin library
has been widened.

## runMetaHook API

GHC 9.4.8 exposes `runMetaHook` in `GHC.Driver.Hooks`:

```haskell
data Hooks = Hooks
  { ...
  , runMetaHook :: !(Maybe (GHC.Types.Meta.MetaHook TcM))
  , ...
  }
```

`MetaHook` and `MetaRequest` are in `GHC.Types.Meta`:

```haskell
type MetaHook f = MetaRequest -> LHsExpr GhcTc -> f MetaResult

data MetaRequest
  = MetaE  (LHsExpr GhcPs -> MetaResult)
  | MetaP  (LPat GhcPs -> MetaResult)
  | MetaT  (LHsType GhcPs -> MetaResult)
  | MetaD  ([LHsDecl GhcPs] -> MetaResult)
  | MetaAW (Serialized -> MetaResult)
```

`defaultRunMeta` is available:

```haskell
defaultRunMeta :: MetaHook TcM
```

from:

```text
GHC.Tc.Gen.Splice
```

This is close enough to the GHC 9.8.4 hook shape for a compatibility layer.

## Parser API

The fragment parser APIs needed by `THCross.ParseFragment` are present:

```haskell
type ParserOpts

initParserState
  :: ParserOpts -> StringBuffer -> RealSrcLoc -> PState

newtype P a = P { unP :: PState -> ParseResult a }

parseExpression :: P ECP

runPV :: PV a -> P a

unECP :: forall b. DisambECP b => PV (LocatedA b)
```

`mkParserOpts` in GHC 9.4.8 has this shape:

```haskell
mkParserOpts
  :: EnumSet Extension
  -> DiagOpts
  -> [String]
  -> Bool
  -> Bool
  -> Bool
  -> Bool
  -> ParserOpts
```

The current parser helper is likely portable with only Cabal bounds and imports
checked.

## Diagnostics API Difference

One known difference is diagnostics forwarding.

The current GHC 9.8+ plugin uses:

```haskell
GHC.Tc.Errors.Types.THError
GHC.Tc.Errors.Types.ReportCustomQuasiError
GHC.Tc.Errors.Types.TcRnTHError
```

In GHC 9.4.8, `THError` is not in scope from `GHC.Tc.Errors.Types`.

Available functions:

```haskell
addErr        :: TcRnMessage -> TcRn ()
addDiagnostic :: TcRnMessage -> TcRn ()
```

`TcRnMessage` has:

```haskell
TcRnUnknownMessage :: (Diagnostic a, Typeable a) => a -> TcRnMessage
```

So a GHC 9.4.8 compatibility path can likely replay worker diagnostics by
introducing a small custom diagnostic type and wrapping it with
`TcRnUnknownMessage`, instead of using the GHC 9.8+ TH-specific constructors.

## Nix Build Result

`flake.nix` exposes a native GHC 9.4.8 plugin build:

```text
packages.x86_64-linux.consumer-ghc948-plugin
packages.x86_64-linux.consumer-ghc948-ghc
checks.x86_64-linux.consumer-ghc948-worker-smoke
```

Run:

```bash
nix build .#consumer-ghc948-plugin -L
```

This currently succeeds. The first API issue encountered was:

```text
Could not find module `GHC.Driver.DynFlags`
```

The parser helper now imports `DynFlags`, `extensionFlags`, `getDynFlags`, and
`targetPlatform` from `GHC.Driver.Session`, which works for both GHC 9.4.8 and
the existing GHC 9.8+/9.10 paths.

The GHC 9.4.8 compatibility path also uses:

- CPP around `LangJs`, which does not exist in GHC 9.4.8's `ForeignSrcLang`;
- CPP around diagnostics replay, because GHC 9.4.8 does not expose the GHC
  9.8+ `THError`/`TcRnTHError` constructors used for proper warning/error
  forwarding.

For now, GHC 9.4.8 diagnostics replay is intentionally minimal:

- worker errors become `fail`;
- worker warnings are printed to stdout.

This is enough for the first plugin build and simple splice-flow checks, but it
is not yet equivalent to the GHC 9.8+ diagnostics replay.

The smoke test compiles the existing simple expression fixture with GHC 9.4.8,
loads the GHC 9.4.8 build of `THCross.Plugin`, and points it at the native GHC
9.8.4 worker:

```bash
nix build .#checks.x86_64-linux.consumer-ghc948-worker-smoke -L
```

The expected path is:

```text
GHC 9.4.8 consumer
  -> THCross.Plugin built with GHC 9.4.8
  -> th-host-worker built with GHC 9.8.4
  -> textual Haskell fragment
  -> GHC 9.4.8 parser
```

## Confirmed Result

The tested mechanism works for a simple expression splice with different
consumer and host-worker GHC versions:

```text
GHC 9.4.8 consumer
  -> THCross.Plugin built with GHC 9.4.8
  -> th-host-worker built with GHC 9.8.4
  -> textual Haskell fragment
  -> GHC 9.4.8 parser
```

This confirms that the textual-fragment protocol does not require the consumer
plugin and the host worker to be built with the same GHC version for this tested
case.

The source/API checks also confirm that GHC 9.4.8 has the pieces needed by the
current prototype:

- `runMetaHook` exists;
- `MetaHook` has the same essential shape;
- all basic `MetaRequest` constructors, including `MetaAW`, exist;
- parser entrypoints needed by expression/type/pattern/declaration fragment
  parsing are present;
- the plugin library now builds with native GHC 9.4.8 through Nix;
- the native GHC 9.4.8 smoke test exercises the existing GHC 9.8.4 host worker.

Current limitations:

- only the tested expression-splice path is confirmed;
- diagnostics replay for GHC 9.4.8 is intentionally minimal;
- annotation binary replay is not covered by this compatibility check;
- real cross-target package sets still need separate validation.

The next implementation step should be trying the same setup through
`pkgsCross.aarch64-multiplatform.haskell.packages.ghc948`.
