# Legacy Cross-Version Textual Protocol

This document records historical plugin-based cross-version tests for the
textual-result TH cross prototype.

This is no longer the production direction. The current production direction is
a same-GHC protocol that transports binary-encoded Template Haskell AST values
instead of pretty-printed Haskell source. Cross-version textual transport remains
useful context for understanding earlier design choices, but it is now legacy.

Current status:

```text
supported plugin GHCs: 9.10 <= GHC < 9.11
active consumer GHC:   9.10.3
active worker GHC:     patched 9.10.3
current payload:       same-GHC Binary Template Haskell AST
textual payload:       rejected legacy experiment
cross-version support: not a production goal
```

The textual experiment was rejected because pretty-printed Haskell is not a
complete representation of TH results. Real packages can generate references to
names whose constructors or helper functions live in internal/non-exported
modules. `aeson` TH exposes this failure mode: the generated source can require
entities that the consumer module cannot legally import or reference. Raw TH AST
transport preserves resolved `TH.Name`s and avoids forcing the result through a
source-level API boundary.

## Goal

The original goal was to verify that the host worker and the consumer compiler
did not have to use the same GHC version when the wire format was textual
Haskell. The currently supported plugin API baseline is GHC 9.8, so older
consumer compilers are no longer supported by the plugin package.

```text
consumer GHC 9.10.x → host worker GHC 9.8.4   (legacy textual path)
```

The main expression-splice test intentionally does not transfer:

```text
GhcPs
GhcRn
Template Haskell AST binary data
```

`MetaAW` annotation wrappers are tested separately below because they currently
use a binary `GHC.Serialized.Serialized` payload.

## Test Script

The repeatable script is:

```text
prototype/cross-version-plugin-test/run.sh
```

It does the following:

1. Builds `th-host-worker` with `ghc-9.8.4`.
2. Builds `th-cross-plugin` with the consumer GHC.
3. Compiles `prototype/th-cross-plugin/test/fixtures/Example.hs` with
   the consumer GHC.
4. Passes the GHC 9.8.4 worker path through
   `-fplugin-opt=THCross.Plugin:worker=...`.

The fixture contains an expression splice:

```haskell
foo :: Int
foo = $([| 42 |])
```

By default the script runs `Example.hs`. A different fixture can be selected
with `FIXTURE`:

```bash
FIXTURE=AnnotationInt.hs prototype/cross-version-plugin-test/run.sh
```

`EXPECT_EXIT=failure` can be used for probes that are expected to fail:

```bash
FIXTURE=AnnotationInt.hs EXPECT_EXIT=failure prototype/cross-version-plugin-test/run.sh
```

## GHC 9.10.x Consumer

### Observed Output

A manual GHC 9.10.2 run produced:

```text
th-cross: intercepted Template Haskell splice
module: Example
kind: expression
splice-key: db5b38a182e7327256576d7231cf0980
location: prototype/th-cross-plugin/test/fixtures/Example.hs:6:8-17
expression: ([| 42 |])
worker: …/th-host-worker/build/th-host-worker/th-host-worker
th-cross: started worker …/th-host-worker/build/th-host-worker/th-host-worker
th-host-worker: cache miss prototype/th-cross-plugin/test/fixtures/Example.hs
```

This confirmed that the consumer-side plugin could be loaded by a GHC 9.10.x
compiler and that splice evaluation could be delegated to a worker built with
GHC 9.8.4. The active Nix consumer compiler is now GHC 9.10.3.

## Historical GHC 9.4.8 Consumer Probe

A previous cross-version check was performed with GHC 9.4.8 as the consumer
compiler.  At the time, plain nixpkgs did not provide cross GHC 9.8.4 for
`pkgsCross.aarch64-multiplatform`, but it did evaluate cross GHC 9.4.8.
The question was whether the plugin could be built against GHC 9.4.8 and
whether the cross-version protocol held.

This path is now historical. The plugin package intentionally requires
GHC 9.10.x and the active protocol requires the plugin, worker, and
`template-haskell` package to come from the same patched GHC.

### API Compatibility

For the legacy textual experiment, GHC 9.4.8 exposed `runMetaHook` with the same `MetaHook` shape as 9.8.4.
All basic `MetaRequest` constructors (`MetaE`, `MetaP`, `MetaT`, `MetaD`,
`MetaAW`) were present.
Two minor differences required `CPP` in the plugin:

- `LangJs` does not exist in GHC 9.4.8's `ForeignSrcLang`;
- diagnostics forwarding uses `TcRnUnknownMessage` instead of the GHC 9.8+
  `TcRnTHError`/`ReportCustomQuasiError` constructors.

### Result

The native cross-version smoke test passed: GHC 9.4.8 loaded
`THCross.Plugin`, delegated to the GHC 9.8.4 worker, and the worker
returned a textual fragment that GHC 9.4.8 parsed successfully.

This confirmed the textual-fragment protocol with a second version pair.

### Cross-Compilation Blocked

The cross-GHC 9.4.8 path is blocked: the plain-nixpkgs GHC 9.4.8 cross
compiler does not expose `-fplugin-library`, and the normal `-fplugin` path
requires a target interpreter that is unavailable.  See
`docs/plain-nixpkgs-cross-ghc.md` for the full investigation.

```text
GHC 9.4.8 native consumer:   works
GHC 9.4.8 cross compiler:    blocked (no -fplugin-library, no interpreter)
```

## Cabal Bounds

The plugin library is built against GHC 9.8 and 9.10:

```cabal
base >= 4.19 && < 4.22
ghc >= 9.8 && < 9.11
ghc-boot >= 9.8 && < 9.11
```

The host worker remains pinned to GHC 9.8.4.

## Scope

Confirmed:

- expression splice interception by the GHC 9.10.x plugin;
- request/response with a GHC 9.8.4 worker;
- textual generated Haskell as the legacy cross-version boundary;
- local parsing by the consumer GHC.

Not confirmed by this test:

- broad source compatibility across future GHC APIs;
- semantic compatibility for target-specific CPP or target-only imports.
- production compatibility for the planned binary Template Haskell AST payload.

## Binary Annotation Wrapper Probe

Annotation declarations are the interesting binary-path probe. These fixtures
use direct source annotations:

```haskell
{-# ANN module (42 :: Int) #-}
{-# ANN module (Ann "th-cross" 42) #-}
```

That path can force `MetaAW`, where the host worker returns a binary-encoded
`GHC.Serialized.Serialized` value. Unlike normal expression/type/pattern/
declaration expansions, this is not textual Haskell.

`Serialized` is not documented as a stable public wire protocol. However, there
is also no practical reason to assume it changes on every GHC release. The
prototype therefore treats `MetaAW` as conditionally cross-version-compatible:
supported GHC version pairs must be covered by explicit compatibility probes.

Run:

```bash
FIXTURE=AnnotationInt.hs prototype/cross-version-plugin-test/run.sh
FIXTURE=AnnotationCustom.hs prototype/cross-version-plugin-test/run.sh
```

Observed `Int` annotation result:

```text
th-cross: intercepted Template Haskell splice
module: AnnotationInt
kind: annotation-wrapper
splice-key: de2aaf5118279fb85eb157a3d932825b
location: …/th-cross-plugin/test/fixtures/AnnotationInt.hs:5:1-30
expression: toAnnotationWrapper (42 :: Int)
worker: …/th-host-worker/build/th-host-worker/th-host-worker
th-cross: started worker …/th-host-worker/build/th-host-worker/th-host-worker
th-host-worker: cache miss …/th-cross-plugin/test/fixtures/AnnotationInt.hs
host GHC: 9.8.4
consumer GHC: 9.10.2
fixture: AnnotationInt.hs
compile exit: 0
```

Observed custom annotation result:

```text
th-cross: intercepted Template Haskell splice
module: AnnotationCustom
kind: annotation-wrapper
splice-key: 91888abb09a493c1f4c3cb9c658e1521
location: …/th-cross-plugin/test/fixtures/AnnotationCustom.hs:7:1-38
expression: toAnnotationWrapper (Ann "th-cross" 42)
worker: …/th-host-worker/build/th-host-worker/th-host-worker
th-cross: started worker …/th-host-worker/build/th-host-worker/th-host-worker
th-host-worker: cache miss …/th-cross-plugin/test/fixtures/AnnotationCustom.hs
host GHC: 9.8.4
consumer GHC: 9.10.2
fixture: AnnotationCustom.hs
compile exit: 0
```

Interpretation:

- the current GHC 9.8.4 and 9.10.2 `Serialized` binary payloads are compatible
  for an `Int` annotation and a custom `Data` annotation;
- this is only an observed compatibility point, not a stable protocol contract;
- `MetaAW` should be tested for every supported host/consumer GHC pair;
- broader annotation values and future GHC versions need more entries in this
  matrix.

`AddTopDeclsAnnotation.hs` is a separate mixed-path case. It first transports
generated declaration text through `addTopDecls`, and that generated declaration
can then trigger `MetaAW`. This is useful, but it is not a clean binary
compatibility probe because failures can also come from declaration
pretty-print/reparse round-tripping.
