# TH cross Nix tool

`th-cross-nix-tool` is the single helper executable used by the Nix
cross-compilation experiments.

It keeps Cabal/package-db inspection out of long inline shell snippets in
`nix/flake/experiments/consumer-ghc9103-cross.nix`. The executable is intentionally
thin; most logic lives in library modules under `src/ThCross/NixTools`.

## Commands

### `plugin-config`

Builds the config file consumed by `THCross.Plugin`.

Usage:

```bash
th-cross-nix-tool plugin-config \
  OUTPUT \
  WORKER \
  HOST_GHC_PKG \
  TARGET_GHC_PKG \
  TARGET_PACKAGE_DB \
  [HOST_PACKAGE_NAME...]
```

The command writes config entries such as:

```text
worker=/nix/store/.../bin/th-host-worker
host-package-id=microlens-0.4.14.0-...
unit-id-map=microlens-0.4.14.0=microlens-0.4.14.0-...
host-source-dir=src
host-ghc-option=-DTH_CONSUMER_TARGET_CONTEXT
```

It combines the responsibilities that used to be separate dump tools:

- Cabal `hs-source-dirs` become `host-source-dir=...`.
- Cabal `cpp-options` become `host-ghc-option=...`.
- host package names are resolved with `HOST_GHC_PKG` into exact
  `host-package-id=...` entries.
- raw TH exact-name package ids are mapped to target unit ids via
  `unit-id-map=from-id=target-unit-id`.

The unit-id mapping covers the target component package DB first and then the
target global package DB. Component mappings take precedence in the plugin,
while global mappings cover exact names produced by real TH generators for boot
or global packages, for example `text`.

### `validate-cabal-component-context`

Compares the package names derived at Nix evaluation time with the component
dependency graph that Cabal writes during `Setup configure`.

Usage:

```bash
th-cross-nix-tool validate-cabal-component-context \
  EXPECTED_PACKAGES \
  EXCLUDED_PACKAGES \
  OUTPUT_DIR
```

This is a guardrail for the current implementation: the worker package
environment is still derived from nixpkgs Haskell dependency metadata, not from
a complete Cabal component context model.
