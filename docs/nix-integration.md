# Nix Integration

This document records the first Nix integration step for the TH cross prototype.

## Goal

Task 20's final target is a haskell.nix/cross build where:

```text
buildPackages:
  native th-host-worker
  native host GHC
  host TH dependencies

cross package set:
  cross GHC
  target dependencies
  THCross plugin
```

The first implementation step is intentionally smaller: prove the local Nix
shape before adding Android or haskell.nix cross details. The current flake has
two roles:

- `hostHaskellPkgs`: native host-side Haskell package set, currently GHC 9.8.4;
- `consumerGhc9103HaskellPkgs`: the Haskell package set that consumes
  `THCross.Plugin`, currently native GHC 9.10.3.
- `consumerGhc948HaskellPkgs`: native GHC 9.4.8 compatibility package set for
  the consumer-side plugin.

The consumer package sets are deliberately named by role and GHC version rather
than by target. They mark the places where a future cross target package set
should be introduced.

The current flake exposes only `x86_64-linux` outputs. Adding `aarch64-linux`
to the flake `systems` list would mean "evaluate this flake on an ARM Linux
host"; it would not enable Android cross-compilation. The Android target should
be introduced later as a separate target package set.

## Current Flake

`flake.nix` exposes:

```text
packages.${system}.host-ghc984-worker
packages.${system}.host-ghc984-plugin
packages.${system}.consumer-ghc948-plugin
packages.${system}.consumer-ghc948-ghc
packages.${system}.consumer-ghc948-cross-plugin-no-th-smoke
packages.${system}.consumer-ghc948-cross-worker-smoke
packages.${system}.consumer-ghc9103-cross-plugin-library-probe
packages.${system}.consumer-ghc9103-plugin
packages.${system}.consumer-ghc9103-ghc
packages.${system}.consumer-ghc9103-package
packages.${system}.aarch64-linux-cross-probe
checks.${system}.consumer-ghc9103-worker-smoke
checks.${system}.consumer-ghc9103-package
checks.${system}.consumer-ghc948-plugin
checks.${system}.consumer-ghc948-worker-smoke
checks.${system}.cross-target-probe-aarch64-linux
devShells.${system}.default
apps.${system}.regen-cabal-nix
```

The package split mirrors the intended cross architecture, but still runs on one
host architecture:

- `host-ghc984-worker` comes from `hostHaskellPkgs` and is built with GHC 9.8.4;
- `host-ghc984-plugin` is the GHC 9.8.4 plugin build used by the local
  prototype;
- `consumer-ghc948-plugin` is a native GHC 9.4.8 compatibility build for the
  consumer-side plugin;
- `consumer-ghc948-ghc` is a GHC 9.4.8 environment containing
  `th-cross-plugin`;
- `consumer-ghc948-cross-plugin-no-th-smoke` is an explicit aarch64 cross-GHC
  plugin-loading smoke test without Template Haskell splices;
- `consumer-ghc948-cross-worker-smoke` is an explicit aarch64 cross-GHC smoke
  test with a Template Haskell splice. These cross smoke packages are not part
  of `flake check`, because they may build the large cross-GHC closure;
- `consumer-ghc9103-cross-plugin-library-probe` checks whether the plain
  nixpkgs aarch64 cross-GHC 9.10.3 can load `THCross.Plugin` through
  `-fplugin-library`. It writes a report instead of failing the derivation,
  because the current result is an expected blocker;
- `consumer-ghc9103-plugin` comes from `consumerGhc9103HaskellPkgs` and is
  built with GHC 9.10.3;
- `consumer-ghc9103-ghc` is a `consumerGhc9103HaskellPkgs` GHC environment
  containing `th-cross-plugin`;
- `checks.${system}.consumer-ghc9103-worker-smoke` compiles `Example.hs` with
  `consumer-ghc9103-ghc` and passes the Nix-built GHC 9.8.4 worker path to the
  plugin.
- `consumer-ghc9103-package` is a minimal Cabal package from
  `consumerGhc9103HaskellPkgs`,
  configured with `THCross.Plugin` plus the Nix-built GHC 9.8.4 worker path.
  The Nix derivation injects those flags into the library component
  `ghc-options` so Cabal's configure-time compiler sanity check does not try to
  load the plugin before package dependencies are registered.
- `aarch64-linux-cross-probe` records the plain nixpkgs
  `pkgsCross.aarch64-multiplatform` split without pretending that a real GHC
  9.8.4 target package set is available there.

The Nix worker derivation wraps `th-host-worker` with:

```text
TH_HOST_GHC_LIBDIR=/nix/store/...-ghc-9.8.4/lib/ghc-9.8.4/lib
```

This prevents the worker from discovering the consumer GHC 9.10.3 via `PATH`
while evaluating host-side TH.
The libdir is passed explicitly from `flake.nix`; it is not inferred from a
generic `ghc` argument in the worker wrapper, because that can accidentally
resolve to the consumer compiler package set.

The Haskell package derivations are checked in under `nix/generated/` instead
of using `callCabal2nix` during flake evaluation. This avoids requiring
`allow-import-from-derivation`.

Files under `nix/generated/` are generated from Cabal files and may be
overwritten by `nix run .#regen-cabal-nix`. Files directly under `nix/` are
manual wrappers that apply project-specific overrides, such as disabling tests,
wrapping the worker with `TH_HOST_GHC_LIBDIR`, and injecting plugin options into
the consumer example.

`th-cross-plugin` package test suites are disabled in the package derivation.
The existing Cabal integration test expects the repository-level
`prototype/cabal.project`, which is not present in the isolated source tree used
by the package derivation. Nix-level validation is handled by
`checks.${system}.consumer-ghc9103-worker-smoke` instead.

## Commands

Build the native worker:

```bash
nix build .#host-ghc984-worker
```

Build the consumer-side plugin with GHC 9.10.3:

```bash
nix build .#consumer-ghc9103-plugin
```

Build the consumer-side plugin with GHC 9.4.8:

```bash
nix build .#consumer-ghc948-plugin
```

Build the GHC 9.4.8 consumer environment:

```bash
nix build .#consumer-ghc948-ghc
```

The same build is also part of:

```bash
nix flake check
```

Run the GHC 9.4.8 consumer plugin smoke test against the GHC 9.8.4 worker:

```bash
nix build .#checks.x86_64-linux.consumer-ghc948-worker-smoke -L
```

Run the explicit aarch64 cross-GHC 9.4.8 smoke test against the native GHC
9.4.8 plugin and GHC 9.8.4 worker:

```bash
nix build .#consumer-ghc948-cross-worker-smoke -L
```

Run the same cross-GHC/plugin wiring without Template Haskell splices:

```bash
nix build .#consumer-ghc948-cross-plugin-no-th-smoke -L
```

These are intentionally packages, not default flake checks. Building them may
pull in the full plain-nixpkgs aarch64 cross-GHC 9.4.8 closure.

Current result: the correct build-host executable cross-GHC is
`pkgsCross.aarch64-multiplatform.buildPackages.haskell.compiler.ghc948`.
Its wrapper reports:

```text
("cross compiling","YES")
```

and the internal compiler binary is `x86-64`. This is the correct shape for
loading a native GHC plugin.

The current blocker is GHC 9.4's cross-GHC plugin loading path. A control
compile of `NoTH.hs` without `-fplugin` succeeds with `-fno-external-interpreter`.
The same `NoTH.hs` compile with `THCross.Plugin` enabled fails before any
Template Haskell splice is involved:

```text
Couldn't find a target code interpreter. Try with -fexternal-interpreter
```

Using `-fexternal-interpreter` is not accepted with plugins:

```text
Plugins require -fno-external-interpreter
```

So the blocker is earlier than `runMetaHook`: this GHC 9.4 cross setup requires
a target code interpreter just to load/use a GHC plugin.

The source-level analysis and possible workaround paths are recorded in
`docs/plain-nixpkgs-cross-ghc.md`.

Run the explicit aarch64 cross-GHC 9.10.3 `-fplugin-library` probe:

```bash
nix build .#consumer-ghc9103-cross-plugin-library-probe -L
cat result
```

Current result: plain nixpkgs provides an aarch64-producing GHC 9.10.3
build-host executable, and that executable exposes `-fplugin-library`. The
probe still cannot load the external static plugin because this GHC package was
built without the internal interpreter code path needed by
`GHC.Driver.Plugins.loadExternalPlugins`:

```text
loadExternalPlugins: can't load external plugins with GHC built without internal interpreter
```

Build the consumer GHC environment:

```bash
nix build .#consumer-ghc9103-ghc
```

Build the package-level consumer example:

```bash
nix build .#consumer-ghc9103-package
```

Inspect the plain nixpkgs aarch64-linux cross probe:

```bash
nix build .#aarch64-linux-cross-probe
cat result
```

Run the local cross-version check:

```bash
nix flake check
```

Regenerate checked-in Cabal-derived Nix files after `.cabal` changes:

```bash
nix run .#regen-cabal-nix
```

This app is intended for repository maintenance. It writes generated files under
`nix/generated/`; it is not part of pure flake evaluation.

Observed check output:

```text
th-cross-consumer-ghc9103-worker-smoke> th-cross: intercepted Template Haskell splice
th-cross-consumer-ghc9103-worker-smoke> module: Example
th-cross-consumer-ghc9103-worker-smoke> kind: expression
th-cross-consumer-ghc9103-worker-smoke> splice-key: db5b38a182e7327256576d7231cf0980
th-cross-consumer-ghc9103-worker-smoke> location: /nix/store/...-Example.hs:6:8-17
th-cross-consumer-ghc9103-worker-smoke> expression: ([| 42 |])
th-cross-consumer-ghc9103-worker-smoke> worker: /nix/store/...-th-host-worker-0.1.0.0/bin/th-host-worker
th-cross-consumer-ghc9103-worker-smoke> th-cross: started worker /nix/store/...-th-host-worker-0.1.0.0/bin/th-host-worker
th-cross-consumer-ghc9103-worker-smoke> th-host-worker: cache miss /nix/store/...-Example.hs
```

This confirms the local Nix wiring:

```text
GHC 9.10.3 plugin package
  -> /nix/store host worker built with GHC 9.8.4
  -> textual expression expansion
```

The package-level check additionally confirms that plugin options can be wired
through a Cabal package derivation rather than only through a direct `ghc`
invocation.

Observed package-level output:

```text
th-consumer-example> Building library for th-consumer-example-0.1.0.0...
th-consumer-example> [1 of 1] Compiling Example
th-consumer-example> th-cross: intercepted Template Haskell splice
th-consumer-example> module: Example
th-consumer-example> kind: expression
th-consumer-example> location: src/Example.hs:6:8-17
th-consumer-example> expression: ([| 42 |])
th-consumer-example> worker: /nix/store/...-th-host-worker-0.1.0.0/bin/th-host-worker
th-consumer-example> th-cross: started worker /nix/store/...-th-host-worker-0.1.0.0/bin/th-host-worker
th-consumer-example> th-host-worker: cache miss src/Example.hs
```

`th-consumer-example` disables library profiling in its Nix derivation so the
check does not compile a separate profiling object variant and does not execute
the same splice a second time only for `*.p_o` output.

Observed cross-probe output:

```text
buildPlatform=x86_64-unknown-linux-gnu
targetHostPlatform=aarch64-unknown-linux-gnu
nativeHostGhc=9.8.4
crossGhc948=9.4.8
targetSideGhc948Compiler=ghc-aarch64-unknown-linux-gnu-9.4.8
buildHostCrossGhc948Compiler=aarch64-unknown-linux-gnu-ghc-9.4.8
consumerPluginShape=native build-host plugin built by consumer-ghc948-plugin
crossGhc984Status=unsupported by plain nixpkgs cross set: GHC >= 9.6 can't be cross-compiled here
nextStep=run consumer-ghc948-cross-worker-smoke to test cross-GHC plus native same-version plugin plus GHC 9.8.4 worker
```

This check is intentionally not a Haskell cross build. It records the current
plain nixpkgs limitation: evaluating cross GHC 9.8.4 in
`pkgsCross.aarch64-multiplatform` fails with nixpkgs' own
`GHC >= 9.6 can't be cross-compiled` error. The useful parts for the prototype
are:

- `buildPackages` still provides a native GHC 9.8.4 side, which is the right
  place for the host worker;
- plain nixpkgs exposes an aarch64-producing GHC 9.4.8 package set;
- the plugin should come from the native GHC 9.4.8 package set, because
  `-fplugin` loads code into the cross-GHC process running on the build host.
- the executable compiler for this smoke test comes from
  `pkgsCross.aarch64-multiplatform.buildPackages.haskell.compiler.ghc948`, not
  from `pkgsCross.aarch64-multiplatform.haskell.compiler.ghc948`.

The explicit `consumer-ghc948-cross-worker-smoke` package tests that wiring by
running the aarch64 cross-GHC with the native GHC 9.4.8 plugin package DB and
the native GHC 9.8.4 worker.

See `docs/plain-nixpkgs-cross-ghc.md` for the plain nixpkgs cross-GHC
investigation.

Enter a shell with both GHC versions and cabal:

```bash
nix develop
```

The shell prints a short command summary on entry.

It also exports linker search paths for Nix-provided native libraries such as
`gmp` and `zlib`. This is needed for manual Cabal builds inside `nix develop`;
otherwise GHC can compile modules but fail during linking with errors such as
`cannot find -lgmp`.

Inside `nix develop`, the shell provides versioned wrappers:

```text
ghc-9.8.4
ghc-9.8.4-pkg
ghc-9.10.3
ghc-9.10.3-pkg
th-cross-build
th-cross-test
```

The helper scripts use a separate Cabal store/build directory:

```text
.cabal-store-nix
dist-newstyle-nix
```

This avoids mixing Nix GHC package ids with packages previously built by ghcup
GHCs.

Build everything:

```bash
th-cross-build
```

Build a specific Cabal target:

```bash
th-cross-build th-host-worker
```

Run the integration test:

```bash
th-cross-test
```

The build helper is equivalent to:

```bash
cabal \
  --store-dir "$PWD/.cabal-store-nix" \
  build \
  --project-dir prototype \
  --builddir dist-newstyle-nix \
  --with-compiler ghc-9.8.4 \
  --with-hc-pkg ghc-9.8.4-pkg \
  all
```

## Next Step

After the local Nix proof works, the next Nix integration step should replace or
supplement the consumer package set with a real target package set:

- a native host package set for `th-host-worker`;
- a target package set for the consumer package;
- a compiler-plugin package database built for the compiler process, not for
  target runtime code;
- plugin configuration that passes:

```text
-fplugin=THCross.Plugin
-fplugin-opt=THCross.Plugin:worker=/nix/store/.../bin/th-host-worker
```

Android/aarch64 should be added only after the local Nix wiring is confirmed.

The current flake intentionally does not add `aarch64-linux` to `systems`.
`systems` controls which host systems evaluate the flake outputs; it is not the
same thing as an Android or aarch64 target package set.
