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
shape before adding Android or haskell.nix cross details.

The current flake exposes only `x86_64-linux` outputs. Adding `aarch64-linux`
to the flake `systems` list would mean "evaluate this flake on an ARM Linux
host"; it would not enable Android cross-compilation. The Android target should
be introduced later as a separate target package set.

## Current Flake

`flake.nix` exposes:

```text
packages.${system}.th-host-worker
packages.${system}.th-cross-plugin-ghc984
packages.${system}.th-cross-plugin-ghc9103
packages.${system}.consumer-ghc9103
checks.${system}.cross-version-plugin
devShells.${system}.default
apps.${system}.regen-cabal-nix
```

The package split mirrors the cross-version prototype:

- `th-host-worker` is built with GHC 9.8.4;
- `th-cross-plugin-ghc9103` is built with GHC 9.10.3;
- `consumer-ghc9103` is a GHC 9.10.3 environment containing
  `th-cross-plugin`;
- the check compiles `Example.hs` with `consumer-ghc9103` and passes the
  Nix-built GHC 9.8.4 worker path to the plugin.

The Haskell package derivations are checked in under `nix/` instead of using
`callCabal2nix` during flake evaluation. This avoids requiring
`allow-import-from-derivation`.

`th-cross-plugin` package test suites are disabled in the package derivation.
The existing Cabal integration test expects the repository-level
`prototype/cabal.project`, which is not present in the isolated source tree used
by the package derivation. Nix-level validation is handled by
`checks.${system}.cross-version-plugin` instead.

## Commands

Build the native worker:

```bash
nix build .#th-host-worker
```

Build the consumer-side plugin with GHC 9.10.3:

```bash
nix build .#th-cross-plugin-ghc9103
```

Build the consumer GHC environment:

```bash
nix build .#consumer-ghc9103
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
`nix/`; it is not part of pure flake evaluation.

Observed check output:

```text
th-cross-cross-version-plugin-check> th-cross: intercepted Template Haskell splice
th-cross-cross-version-plugin-check> module: Example
th-cross-cross-version-plugin-check> kind: expression
th-cross-cross-version-plugin-check> splice-key: db5b38a182e7327256576d7231cf0980
th-cross-cross-version-plugin-check> location: /nix/store/...-Example.hs:6:8-17
th-cross-cross-version-plugin-check> expression: ([| 42 |])
th-cross-cross-version-plugin-check> worker: /nix/store/...-th-host-worker-0.1.0.0/bin/th-host-worker
th-cross-cross-version-plugin-check> th-cross: started worker /nix/store/...-th-host-worker-0.1.0.0/bin/th-host-worker
th-cross-cross-version-plugin-check> th-host-worker: cache miss /nix/store/...-Example.hs
```

This confirms the local Nix wiring:

```text
GHC 9.10.3 plugin package
  -> /nix/store host worker built with GHC 9.8.4
  -> textual expression expansion
```

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

After the local Nix proof works, the haskell.nix step should introduce:

- a native host package set for `th-host-worker`;
- a target package set for the consumer package and `THCross.Plugin`;
- plugin configuration that passes:

```text
-fplugin=THCross.Plugin
-fplugin-opt=THCross.Plugin:worker=/nix/store/.../bin/th-host-worker
```

Android/aarch64 should be added only after the local Nix wiring is confirmed.
