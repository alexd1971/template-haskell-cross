# Cross-Version Host/Consumer GHC Test

This document records the first plugin-based cross-version test for the TH cross
prototype.

## Goal

Verify that the host worker and the consumer compiler do not have to use the
same GHC version when the wire format is textual Haskell:

```text
consumer GHC 9.10.2
  -> THCross.Plugin runMetaHook
  -> host worker built with GHC 9.8.4
  -> generated Haskell text
  -> consumer GHC 9.10.2 parses the text locally
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
2. Builds `th-cross-plugin` with `ghc-9.10.2`.
3. Compiles `prototype/th-cross-plugin/test/fixtures/Example.hs` with
   `ghc-9.10.2`.
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

## Observed Output

The manual run produced:

```text
th-cross: intercepted Template Haskell splice
module: Example
kind: expression
splice-key: db5b38a182e7327256576d7231cf0980
location: prototype/th-cross-plugin/test/fixtures/Example.hs:6:8-17
expression: ([| 42 |])
worker: /home/alexey/Projects/flutter-bridges/th-cross/prototype/dist-newstyle/build/x86_64-linux/ghc-9.8.4/th-host-worker-0.1.0.0/x/th-host-worker/build/th-host-worker/th-host-worker
th-cross: started worker /home/alexey/Projects/flutter-bridges/th-cross/prototype/dist-newstyle/build/x86_64-linux/ghc-9.8.4/th-host-worker-0.1.0.0/x/th-host-worker/build/th-host-worker/th-host-worker
th-host-worker: cache miss prototype/th-cross-plugin/test/fixtures/Example.hs
```

This confirms that the consumer-side plugin was loaded by GHC 9.10.2 and that
splice evaluation was delegated to a worker built with GHC 9.8.4.

## Cabal Bounds

The plugin library is now allowed to build against both GHC 9.8 and GHC 9.10:

```cabal
base >= 4.19 && < 4.22
ghc >= 9.8 && < 9.11
ghc-boot >= 9.8 && < 9.11
```

The host worker remains pinned to GHC 9.8.4. This is intentional: Task 19 is
about a GHC 9.8.4 host-side evaluator serving a different consumer GHC.

## Scope

Confirmed:

- expression splice interception by a GHC 9.10.2 plugin;
- request/response with a GHC 9.8.4 worker;
- textual generated Haskell as the cross-version boundary;
- local parsing by the consumer GHC.

Not confirmed by this test:

- broad source compatibility across future GHC APIs;
- semantic compatibility for target-specific CPP or target-only imports.

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
location: /home/alexey/Projects/flutter-bridges/th-cross/prototype/th-cross-plugin/test/fixtures/AnnotationInt.hs:5:1-30
expression: toAnnotationWrapper (42 :: Int)
worker: /home/alexey/Projects/flutter-bridges/th-cross/prototype/dist-newstyle/build/x86_64-linux/ghc-9.8.4/th-host-worker-0.1.0.0/x/th-host-worker/build/th-host-worker/th-host-worker
th-cross: started worker /home/alexey/Projects/flutter-bridges/th-cross/prototype/dist-newstyle/build/x86_64-linux/ghc-9.8.4/th-host-worker-0.1.0.0/x/th-host-worker/build/th-host-worker/th-host-worker
th-host-worker: cache miss /home/alexey/Projects/flutter-bridges/th-cross/prototype/th-cross-plugin/test/fixtures/AnnotationInt.hs
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
location: /home/alexey/Projects/flutter-bridges/th-cross/prototype/th-cross-plugin/test/fixtures/AnnotationCustom.hs:7:1-38
expression: toAnnotationWrapper (Ann "th-cross" 42)
worker: /home/alexey/Projects/flutter-bridges/th-cross/prototype/dist-newstyle/build/x86_64-linux/ghc-9.8.4/th-host-worker-0.1.0.0/x/th-host-worker/build/th-host-worker/th-host-worker
th-cross: started worker /home/alexey/Projects/flutter-bridges/th-cross/prototype/dist-newstyle/build/x86_64-linux/ghc-9.8.4/th-host-worker-0.1.0.0/x/th-host-worker/build/th-host-worker/th-host-worker
th-host-worker: cache miss /home/alexey/Projects/flutter-bridges/th-cross/prototype/th-cross-plugin/test/fixtures/AnnotationCustom.hs
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
