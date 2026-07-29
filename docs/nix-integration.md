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
  native patched GHC 9.10.3
  th-host-worker
  host-side TH dependencies

consumer plugin:
  native GHC 9.10.3
  th-cross-plugin shared library loaded into the compiler process
  th-cross-protocol dependency

target package set:
  patched aarch64-linux cross-GHC 9.10.3
  target dependencies and package DBs
```

The host worker and the cross compiler must use compatible
`ghc`/`template-haskell` ABIs because the worker sends binary-encoded raw
Template Haskell AST values. The old textual transport is legacy and is not used
for package-level cross builds.

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
```

`target-ghc9103-protocol` contains the shared binary protocol and splice-key
types used by both the plugin and the worker.

`patched-ghc9103` is the native worker compiler. It applies
`ghc-9.10.3-export-runth.patch`, which exports raw TH runner functions and
captures raw `addTopDecls` payloads.

`cross-ghc9103-aarch64-linux` is the patched aarch64 cross compiler used by the
package-level consumer builds. Its cross-specific patches are documented in
`docs/ghc-cross-patches.md`.

`lib.${system}.ghc9103Aarch64Linux` is the reusable API intended for external
consumer flakes. It exposes:

- `crossHaskellPkgs`: target Haskell package set built around the patched
  aarch64-linux GHC 9.10.3.
- `callPackageWithWorker`: call a cabal2nix-generated package while injecting
  the TH cross plugin, worker, plugin config, package DB mapping, source dirs,
  CPP options, and context validation.
- `callPackageCabalContextProbe`: build only the Cabal context validation probe
  for a package.
- `mkDerivationWithWorker`: lower-level `mkDerivation` override for package
  definitions that are not loaded from a cabal2nix file.

## External Consumer Flake

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
      thCross = th-cross.lib.${system}.ghc9103Aarch64Linux;
    in
    {
      packages.${system}.default =
        thCross.callPackageWithWorker ./generated/my-package.nix;
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
      thCross = th-cross.lib.${system}.ghc9103Aarch64Linux;
    in
    {
      packages.${system}.default =
        thCross.callPackageWithWorker ./nix/generated/my-package.nix;
    };
}
```

Build:

```bash
nix build --no-write-lock-file . -L
```

If dependency resolution looks wrong, first inspect the Cabal context that the
integration sees:

```nix
packages.${system}.cabal-context-probe =
  thCross.callPackageCabalContextProbe ./nix/generated/my-package.nix;
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
- Use the template only for new packages. Existing packages should normally add
  a flake wrapper and generated expression rather than copying the scaffold.
- Commit `flake.lock` for real external packages. The repository examples use
  `--no-write-lock-file` only to avoid fixture lock churn.
- Current reusable API targets `x86_64-linux` hosts and the
  `ghc9103Aarch64Linux` target package set.

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

and builds its package through `thCross.callPackageWithWorker`.

They can be evaluated like external flakes without writing fixture lock files:

```bash
nix build --no-write-lock-file ./examples/aeson
nix build --no-write-lock-file ./examples/microlens
nix build --no-write-lock-file ./examples/target-context
nix build --no-write-lock-file ./examples/executable
```

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
