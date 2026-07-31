# Nix Integration

This document describes the current Nix shape of TH cross-compilation support.
Historical cross-version and textual-protocol experiments are kept in
`docs/cross-version.md` and `docs/plain-nixpkgs-cross-ghc.md`. Current
source-level GHC version compatibility notes are tracked in
`docs/ghc-version-support.md`.

## Architecture

The active path has three compiler/package roles:

```text
host worker:
  native patched GHC from the selected compiler profile
  th-host-worker
  host-side TH dependencies

consumer plugin:
  native GHC from the selected compiler profile
  th-cross-plugin shared library loaded into the compiler process
  th-cross-protocol dependency

target package set:
  patched target cross-GHC from the selected compiler profile
  target dependencies and package DBs
```

The host worker and the cross compiler must use compatible
`ghc`/`template-haskell` ABIs because the worker sends binary-encoded raw
Template Haskell AST values. The old textual transport is legacy and is not used
for package-level cross builds.

The target Haskell package set disables nixpkgs' default cross
`enableExternalInterpreter` path. TH execution is handled by `th-host-worker`,
so target package builds should not pull `iserv-proxy`, `iserv-wrapper`, or
emulators such as `qemu-user` just to support cross TH.

The current flake exposes only `x86_64-linux` outputs. Adding `aarch64-linux` to
the flake `systems` list would mean "evaluate this flake on an ARM Linux host";
it would not create an Android or aarch64 target package set.

## Important Outputs

```text
packages.${system}.patched-ghc9103
packages.${system}.host-ghc9103-worker
packages.${system}.target-ghc9103-protocol
packages.${system}.target-ghc9103-plugin
packages.${system}.target-ghc9103-with-plugin
packages.${system}.target-ghc9103-target-context-package
packages.${system}.cross-ghc9103-aarch64-linux
packages.${system}.th-cross-nix-tools
checks.${system}.target-ghc9103-worker-smoke
checks.${system}.target-ghc9103-target-context-package
apps.${system}.regen-cabal-nix
devShells.${system}.default
lib.${system}.ghc9103Aarch64Linux
lib.${system}.mkCrossFor
lib.${system}.mkAarch64LinuxForVersion
```

`target-ghc9103-protocol` contains the shared binary protocol and splice-key
types used by both the plugin and the worker.

`patched-ghc9103` is the native worker compiler. It applies
`export-runth.patch`, which exports raw TH runner functions and
captures raw `addTopDecls` payloads.

The compatibility outputs above point at the GHC 9.10.3 profile. New consumer
flakes should prefer `lib.${system}.mkCrossFor`, which accepts `ghcVersion` and
`target`.

`cross-ghc9103-aarch64-linux` is the patched aarch64 cross compiler used by the
package-level consumer builds. Its cross-specific patches are documented in
`docs/ghc-cross-patches.md`.

`lib.${system}.mkCrossFor` is the reusable API intended for external consumer
flakes. It currently accepts these target names:

- `aarch64-linux`: validated with all examples.
- `aarch64-android`: backed by nixpkgs `aarch64-android-prebuilt`; target
  profile validates with all examples for GHC 9.10.3 and enables shared
  Haskell libraries.

`lib.${system}.mkAarch64LinuxForVersion` and
`lib.${system}.ghc9103Aarch64Linux` are compatibility aliases for the
`aarch64-linux` target. The API exposes:

- `crossHaskellPkgs`: target Haskell package set built around the patched
  target GHC for the selected compiler profile.
- `buildPackage`: build a cabal2nix-generated package while injecting
  the TH cross plugin, worker, plugin config, package DB mapping, source dirs,
  CPP options, and context validation.
- `checkCabalContext`: build only the Cabal context validation probe for a
  package.
- `mkDerivationWithWorker`: lower-level `mkDerivation` override for package
  definitions that are not loaded from a cabal2nix file.

`callPackageWithWorker` and `callPackageCabalContextProbe` remain available as
compatibility names for the lower-level implementation.

## External Consumer Flake

For a step-by-step guide for existing packages, see
`docs/external-project-integration.md`.

A consumer package flake can use this repository as an input and build a target
package through the exported API:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    th-cross.url = "github:alexd1971/template-haskell-cross";
  };

  outputs = { nixpkgs, th-cross, ... }:
    let
      system = "x86_64-linux";
      thCross = th-cross.lib.${system}.mkCrossFor {
        ghcVersion = "9.10.3";
        target = "aarch64-linux";
      };
    in
    {
      packages.${system}.default =
        thCross.buildPackage ./generated/my-package.nix;
    };
}
```

The package file should be a normal cabal2nix-generated expression. The helper
reuses its `getCabalDeps` metadata to derive the host-side worker package set.
At configure time it validates that this evaluation-time dependency set matches
Cabal's configured component graph.

## Existing Package Migration

For an existing Cabal package, keep the Cabal file as the source of truth and
add only the Nix wrapper needed to load `th-cross`.

Minimal layout:

```text
my-package/
  flake.nix
  my-package.cabal
  src/...
  app/...
  nix/generated/my-package.nix
```

Generate the package expression from the package root:

```bash
mkdir -p nix/generated
cabal2nix . > nix/generated/my-package.nix
```

Add a flake that delegates the package derivation to `th-cross`:

```nix
{
  inputs = {
    th-cross.url = "github:alexd1971/template-haskell-cross";
  };

  outputs = { th-cross, ... }:
    let
      system = "x86_64-linux";
      ghcVersion =
        let value = builtins.getEnv "TH_CROSS_GHC_VERSION";
        in if value == "" then "9.10.3" else value;
      target =
        let value = builtins.getEnv "TH_CROSS_TARGET";
        in if value == "" then "aarch64-linux" else value;
      thCross = th-cross.lib.${system}.mkCrossFor { inherit ghcVersion target; };
    in
    {
      packages.${system}.default =
        thCross.buildPackage ./nix/generated/my-package.nix;
    };
}
```

Build:

```bash
nix build --no-write-lock-file . -L
TH_CROSS_GHC_VERSION=9.12.4 TH_CROSS_TARGET=aarch64-linux nix build --impure --no-write-lock-file . -L
```

If dependency resolution looks wrong, first inspect the Cabal context that the
integration sees:

```nix
packages.${system}.cabal-context-probe =
  thCross.checkCabalContext ./nix/generated/my-package.nix;
```

Then run:

```bash
nix build --no-write-lock-file .#cabal-context-probe -L
cat result/nix-support/cabal-component-deps
cat result/nix-support/nix-derived-host-package-names
```

Operational rules:

- Regenerate `nix/generated/my-package.nix` after changing `build-depends`,
  components, `hs-source-dirs`, or Cabal conditionals.
- Keep TH generator dependencies in normal `build-depends`; the wrapper derives
  the host worker package environment from the cabal2nix metadata.
- The internal `th-cross-nix-tool` is built from the selected compiler profile
  because its context validator reads Cabal's `dist/setup-config`.
- Use the template only for new packages. Existing packages should normally add
  a flake wrapper and generated expression rather than copying the scaffold.
- Commit `flake.lock` for real external packages. The repository examples use
  `--no-write-lock-file` only to avoid fixture lock churn.
- Current reusable API targets `x86_64-linux` hosts. Select the target and GHC
  compiler profile with `mkCrossFor`.

## New Package Template

Create a scaffold package with:

```bash
nix flake init -t github:alexd1971/template-haskell-cross#cross-app
```

Then edit the generated `flake.nix` and point `inputs.th-cross.url` at the
actual local checkout or remote flake:

```nix
inputs.th-cross.url = "github:alexd1971/template-haskell-cross";
```

Build the generated package:

```bash
nix build . -L
```

The template includes an executable, a small library, an `aeson` TH splice as
an example real TH dependency, and `nix/generated/cross-app.nix`. If the Cabal
file changes, regenerate the package expression with:

```bash
cabal2nix . > nix/generated/cross-app.nix
```

The local examples mirror this external shape. Each `examples/*`
directory contains its own `flake.nix` with:

```nix
inputs.th-cross.url = "path:../..";
```

and builds its package through `thCross.buildPackage`.

They can be evaluated like external flakes without writing fixture lock files:

```bash
nix build --no-write-lock-file ./examples/aeson
nix build --no-write-lock-file ./examples/microlens
nix build --no-write-lock-file ./examples/target-context
nix build --no-write-lock-file ./examples/executable
```

To evaluate examples with another compiler profile:

```bash
TH_CROSS_GHC_VERSION=9.12.4 TH_CROSS_TARGET=aarch64-linux nix build --impure --no-write-lock-file ./examples/aeson -L
TH_CROSS_GHC_VERSION=9.12.4 TH_CROSS_TARGET=aarch64-linux nix build --impure --no-write-lock-file ./examples/microlens -L
TH_CROSS_GHC_VERSION=9.12.4 TH_CROSS_TARGET=aarch64-linux nix build --impure --no-write-lock-file ./examples/target-context -L
TH_CROSS_GHC_VERSION=9.12.4 TH_CROSS_TARGET=aarch64-linux nix build --impure --no-write-lock-file ./examples/executable -L
```

To validate the Android target profile, switch only `TH_CROSS_TARGET`:

```bash
TH_CROSS_GHC_VERSION=9.10.3 TH_CROSS_TARGET=aarch64-android nix build --impure --no-write-lock-file ./examples/aeson -L
TH_CROSS_GHC_VERSION=9.10.3 TH_CROSS_TARGET=aarch64-android nix build --impure --no-write-lock-file ./examples/microlens -L
TH_CROSS_GHC_VERSION=9.10.3 TH_CROSS_TARGET=aarch64-android nix build --impure --no-write-lock-file ./examples/target-context -L
TH_CROSS_GHC_VERSION=9.10.3 TH_CROSS_TARGET=aarch64-android nix build --impure --no-write-lock-file ./examples/executable -L
```

The Android target validates with `aeson`, `microlens`, `target-context`, and
`executable` examples on GHC 9.10.3. Build plans do not include `compiler-rt`,
`qemu-user`, `iserv-proxy`, or `iserv-wrapper`; they use the nixpkgs Android NDK
toolchain wrapper instead. The target profile also forces
`enableSharedLibraries = true` for the target Haskell package set so dependency
packages provide dynamic interface files such as `*.dyn_hi`. Android shared
libraries are cleaned before nixpkgs' `audit-tmpdir` hook so temporary build
package-db entries do not remain in RPATH.

## Plugin Config

The cross package derivations do not pass a long list of
`-fplugin-opt=THCross.Plugin:...` arguments. External plugins loaded through
`-fplugin-library` receive their option list from the fourth
`;`-separated field of the `-fplugin-library` argument. The Nix integration
keeps that field short:

```text
-fplugin-library=$plugin_so;$plugin_unit;THCross.Plugin;["config=/build/<package>/th-cross-plugin-options"]
```

The config file is generated during `preConfigure` by:

```bash
th-cross-nix-tool plugin-config \
  th-cross-plugin-options \
  "$worker" \
  "$hostGhcPkg" \
  "$targetGhcPkg" \
  "$packageConfDir" \
  <host-package-name>...
```

The generated file contains:

- `worker=...` for the host worker executable.
- `host-package-id=...` entries resolved with host `ghc-pkg`.
- `unit-id-map=host-or-source-id=target-unit-id` entries used to rewrite exact
  `TH.NameG` references before `GHC.ThToHs` conversion.
- `host-source-dir=...` entries from all package components.
- `host-ghc-option=...` entries for unconditional Cabal `cpp-options`.

The plugin still accepts inline options for manual direct-`ghc` tests, but the
package-level Nix path should use `config=...`.

## Package DB Handling

The worker needs host-side dependencies for TH generator code. The target
compiler needs target-side dependencies for the generated code.

The Nix experiment derives host package names from nixpkgs'
`passthru.getCabalDeps` metadata, filters boot packages such as `base` and
`template-haskell`, and builds a native GHC 9.10.3 `ghcWithPackages`
environment for those names. The resulting worker wrapper sets:

```text
TH_HOST_GHC_LIBDIR=/nix/store/...-ghc-9.10.3-with-packages/lib/ghc-9.10.3/lib
```

The same host package names are resolved to exact unit ids and written to the
plugin config as `host-package-id=...`. The worker turns these into
`-package-id` flags while evaluating the source module.

Raw TH payloads can contain exact names that mention host unit ids or source
package ids. These are not stable lookup keys in the target package DB. The
config generator therefore builds `unit-id-map` entries by matching package
names in:

- the host GHC package DB;
- the target component package DB;
- the target global package DB.

The target component DB is passed with `--package-db="$packageConfDir"`. The
target global DB is queried through the cross `ghc-pkg` without an explicit
package DB. This is needed for generators that emit exact names for global
packages such as `text`.

## Context Validation

Host package selection happens during Nix evaluation, but Cabal's exact
component context is only known after `Setup configure`. Worker-enabled package
builds therefore validate the evaluation-time dependency set against Cabal's
persisted `dist/setup-config` before `Setup build`.

The validation is run by:

```bash
th-cross-nix-tool validate-cabal-component-context \
  "$expected_packages" \
  "$excluded_packages" \
  "$out/nix-support"
```

The helper executable is built from the selected compiler profile, not from a
fixed GHC. This matters because Cabal's persisted `setup-config` is versioned by
the Cabal library used by `Setup configure`; reading it with a helper linked
against a different Cabal version fails before validation can run.

The standalone probe exposes the same data:

```bash
nix build --no-write-lock-file ./examples/microlens#cabal-context-probe -L
cat result/nix-support/cabal-component-deps
```

This is a fail-fast consistency check, not a complete Cabal component-context
model. Known gaps include renamed packages, internal libraries beyond the
current package, setup dependencies, conditional fields not represented in the
simple config generator, generated include directories, `autogen` macros, and
packages whose nixpkgs attribute name differs from the Cabal package name.

## Consumer Builds

Build the current cross-compilation example packages:

```bash
nix build --no-write-lock-file ./examples/target-context -L
nix build --no-write-lock-file ./examples/microlens -L
nix build --no-write-lock-file ./examples/aeson -L
nix build --no-write-lock-file ./examples/executable -L
```

With an explicit GHC version:

```bash
TH_CROSS_GHC_VERSION=9.12.4 TH_CROSS_TARGET=aarch64-linux nix build --impure --no-write-lock-file ./examples/target-context -L
TH_CROSS_GHC_VERSION=9.12.4 TH_CROSS_TARGET=aarch64-linux nix build --impure --no-write-lock-file ./examples/microlens -L
TH_CROSS_GHC_VERSION=9.12.4 TH_CROSS_TARGET=aarch64-linux nix build --impure --no-write-lock-file ./examples/aeson -L
TH_CROSS_GHC_VERSION=9.12.4 TH_CROSS_TARGET=aarch64-linux nix build --impure --no-write-lock-file ./examples/executable -L
```

Coverage:

- `th-target-context-consumer` checks CPP-sensitive source context forwarding.
- `th-microlens-consumer` checks a real declaration generator from
  `microlens-th`.
- `th-aeson-consumer` checks deeper real-package TH from `aeson`, including
  nested records, sum types, `Maybe`, lists, custom field modifiers,
  `TaggedObject` encoding, and a local generator from the current package.
- `th-executable-consumer` checks executable components and same-package source
  module visibility.

Build the lower-level compiler/plugin pieces:

```bash
nix build .#host-ghc9103-worker
nix build .#target-ghc9103-plugin
nix build .#cross-ghc9103-aarch64-linux
```

Run the fast flake checks:

```bash
nix flake check
```

## Development Shell

Enter the shell:

```bash
nix develop
```

The shell provides:

```text
ghc-9.10.3
ghc-9.10.3-pkg
th-cross-build
th-cross-test
```

The wrappers use separate Cabal state:

```text
.cabal-store-nix
dist-newstyle-nix
```

This avoids mixing Nix GHC package ids with packages built by ghcup GHCs.

Build the core Cabal workspace:

```bash
th-cross-build
```

Run integration tests:

```bash
th-cross-test
```

By default this runs:

```bash
th-cross-test th-cross-plugin:integration --test-show-details=direct
```

The helper builds the patched worker through Nix before invoking `cabal test`
and exports `TH_HOST_WORKER`. Building the worker outside the test executable
avoids Cabal store/build lock contention from nested `cabal build` calls.

## Generated Nix Files

Files under `nix/generated/` are checked in and regenerated from Cabal files:

```bash
nix run .#regen-cabal-nix
```

Keeping these files checked in avoids `allow-import-from-derivation` during
normal flake evaluation.

## Cross-GHC Without Interpreter Baggage

The current `cross-ghc9103-aarch64-linux` derivation starts from
`pkgs.pkgsCross.aarch64-multiplatform.buildPackages.haskell.compiler.ghc9103`.
That path is designed for the standard cross-TH story where GHC may use a
target `iserv`. TH cross-compilation support does not use target iserv: splice
evaluation happens in the native worker and the cross compiler only loads a
native plugin.

Current inspection result:

- runtime closure size is about 2.9 GB;
- the installed cross-GHC does not contain `ghc-iserv` or `remote-iserv`
  binaries;
- `network` is not present in the runtime closure or installed package DB;
- target package `ghci` is installed and registered;
- `compiler/ghc.cabal.in` depends on `ghci` unconditionally, while
  `ghc/ghc-bin.cabal.in` adds the interactive UI dependencies only when
  `internal-interpreter` is enabled.

So the immediate optimization target is not a separate `iserv` executable or
`network` package dependency. The visible interpreter-related baggage is the
target `ghci` package and the compiler modules that import `GHCi.*`.

This suggests a follow-up experiment: derive a leaner cross-GHC package from
the same nixpkgs/Hadrian machinery, but make it a separate probe first. The
expected invariant is:

```text
cross GHC still supports normal aarch64 compilation
cross GHC still loads THCross.Plugin through -fplugin-library
cross GHC does not need a target interpreter for TH splice execution
```

The probe should not replace `cross-ghc9103-aarch64-linux` until it passes the
consumer package builds. A safe first step is a
`cross-ghc9103-aarch64-linux-lean-probe` that reports closure/package-db
contents and then tries the smallest source or Hadrian patch needed to remove
unused interpreter pieces.
