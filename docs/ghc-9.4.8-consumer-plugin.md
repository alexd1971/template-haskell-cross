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
packages.x86_64-linux.th-cross-plugin-ghc948
```

Run:

```bash
nix build .#th-cross-plugin-ghc948 -L
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

## Preliminary Conclusion

GHC 9.4.8 looks plausible as a consumer-side target for the textual protocol:

- `runMetaHook` exists;
- `MetaHook` has the same essential shape;
- all basic `MetaRequest` constructors, including `MetaAW`, exist;
- parser entrypoints needed by expression/type/pattern/declaration fragment
  parsing are present;
- the plugin library now builds with native GHC 9.4.8 through Nix;
- diagnostics replay still needs proper compatibility code;
- the host worker can remain GHC 9.8.4.

The next implementation step should be a native GHC 9.4.8 plugin smoke test
with the GHC 9.8.4 host worker before attempting target-side
`pkgsCross.aarch64-multiplatform.haskell.packages.ghc948`.
