# External Project Integration

This guide describes how to use `template-haskell-cross` from an existing
Haskell project that already has its own Cabal package.

The integration model is intentionally Nix-side only:

- keep the package `.cabal` file as the source of truth;
- generate a normal `cabal2nix` expression for the package;
- wrap that generated expression with `th-cross` using `buildPackage`;
- choose an explicitly supported GHC profile and target platform in the flake.

## Supported Inputs

The current public API supports an `x86_64-linux` host and these target names:

- `aarch64-linux`: validated with all examples for GHC 9.8.4, 9.10.3, and
  9.12.4.
- `aarch64-android`: backed by nixpkgs `aarch64-android-prebuilt`; target
  profile validates with all examples for GHC 9.10.3 and enables shared
  Haskell libraries.

Example:

```nix
th-cross.lib.x86_64-linux.mkCrossFor {
  ghcVersion = "9.10.3";
  target = "aarch64-linux";
}
```

For Android:

```nix
th-cross.lib.x86_64-linux.mkCrossFor {
  ghcVersion = "9.10.3";
  target = "aarch64-android";
}
```

Validated GHC patch releases:

- `9.8.4`
- `9.10.3`
- `9.12.4`

Supported release series are expected to be `9.8.x`, `9.10.x`, and `9.12.x`,
but a patch release is only treated as validated after it has a compiler profile
and has passed worker, plugin, integration, and example builds.

## Minimal Layout

For an existing package, add only the Nix wrapper files:

```text
my-package/
  flake.nix
  my-package.cabal
  src/...
  app/...
  nix/
    generated/
      my-package.nix
```

The generated file is a normal `cabal2nix` package expression. Regenerate it
when package dependencies, components, source directories, flags, or Cabal
conditionals change.

```bash
mkdir -p nix/generated
cabal2nix . > nix/generated/my-package.nix
```

## Flake Wrapper

Use this shape for the package flake:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    th-cross.url = "github:alexd1971/template-haskell-cross";
  };

  outputs = { th-cross, ... }:
    let
      system = "x86_64-linux";

      thCross = th-cross.lib.${system}.mkCrossFor {
        ghcVersion = "9.10.3";
        target = "aarch64-linux";
      };
    in
    {
      packages.${system}.default =
        thCross.buildPackage ./nix/generated/my-package.nix;

      packages.${system}.cabal-context-probe =
        thCross.checkCabalContext ./nix/generated/my-package.nix;
    };
}
```

For a real external project, commit `flake.lock`. The examples in this
repository often use `--no-write-lock-file` only to avoid fixture lock churn.

## Build Commands

Default build, using GHC 9.10.3 and `aarch64-linux`:

```bash
nix build . -L
```

To change the compiler or target for a real project, edit the explicit
`ghcVersion` or `target` in `flake.nix`. This keeps CI, local builds, and review
diffs deterministic.

The environment-variable pattern used by repository examples is intentionally
not the recommended shape for external projects. It is useful for matrix
experiments, but production flakes should make the selected compiler profile and
target visible in source.

Run only the Cabal context probe:

```bash
nix build .#cabal-context-probe -L
```

Inspect the generated validation data:

```bash
cat result/nix-support/cabal-component-deps
cat result/nix-support/nix-derived-host-package-names
cat result/nix-support/cabal-derived-package-names
cat result/nix-support/package-name-diff
```

## GHC Version Mismatch

The package's original development compiler does not automatically control the
TH cross build. The raw TH protocol requires the worker GHC, plugin GHC, and
target GHC to come from the same selected compiler profile.

If the existing project uses exactly one validated version, use that version:

```nix
thCross = th-cross.lib.${system}.mkCrossFor {
  ghcVersion = "9.10.3";
  target = "aarch64-linux";
};
```

If the project uses another patch release in a supported series, first try the
nearest validated profile from the same series if the package bounds and
dependencies allow it. For example, a project developed with GHC 9.12.3 can be
tested with the validated 9.12.4 profile:

```nix
thCross = th-cross.lib.${system}.mkCrossFor {
  ghcVersion = "9.12.4";
  target = "aarch64-linux";
};
```

This is an explicit compiler choice, not automatic compatibility. If the
project must be built with the exact compiler version, add a new compiler
profile in `nix/flake/ghc-profiles.nix` and validate it before relying on it.

If the project uses an unsupported series such as GHC 9.6.x or 9.14.x, there is
no safe automatic fallback. Either move the package to a supported profile or
add and validate a new compiler profile for that series.

## Dependency Rules

Template Haskell generator dependencies should stay in normal Cabal
`build-depends`. The Nix wrapper reads the generated package metadata and builds
a matching host-side package environment for the worker.

Common rules:

- Keep `template-haskell` in Cabal dependencies when the package imports TH.
- Keep TH libraries such as `aeson`, `microlens-th`, or custom generators in
  normal `build-depends`.
- Regenerate `nix/generated/my-package.nix` after dependency changes.
- Do not manually pass worker package DBs unless `buildPackage` is not
  enough for a custom derivation.

## Troubleshooting

Unsupported compiler version:

```text
Unsupported GHC version ...
```

Use one of the validated patch releases or add a compiler profile.

Cabal context mismatch:

```text
Nix-derived host package names differ from Cabal setup-config package names
```

Run `.#cabal-context-probe`, inspect the files under `result/nix-support`, and
regenerate the `cabal2nix` expression if it is stale.

Outdated Cabal setup config:

```text
Saved package config file is outdated
```

This usually means a stale `dist` directory was reused across different Cabal or
GHC versions. The wrapper uses version-specific build directories for integration
tests, but external projects should also avoid sharing old `dist` state between
compiler profiles.

Hidden or missing package interfaces during splice evaluation:

```text
Failed to load interface for ...
no unit id matching ...
```

First run the Cabal context probe. The usual cause is that the host worker
package environment does not match the package dependency graph seen by Cabal.
The normal fix is to regenerate the cabal2nix expression and rebuild with the
same explicit `ghcVersion` profile.
