# TH cross Nix tools

Small helper executables used by the Nix cross-compilation experiments.

The tools keep Cabal/package-db inspection out of long inline shell snippets in
`nix/flake/experiments/consumer-ghc9103-cross.nix`.

## Tools

### `dump-cabal-source-dirs`

Reads the package `.cabal` file in the current directory and prints every
non-empty `hs-source-dirs` entry from all components.

The cross experiment passes each line to the plugin as:

```text
host-source-dir=<absolute-source-dir>
```

The host worker needs these directories to load the same source module that the
cross GHC is compiling.

### `dump-cabal-cpp-options`

Reads the package `.cabal` file in the current directory and prints CPP options
from all components.

The cross experiment passes each line to the plugin as:

```text
host-ghc-option=<cpp-option>
```

The host worker applies those options before loading the source module, so TH
reification sees the same CPP-conditioned source shape as the target build.

### `validate-cabal-component-context`

Compares the package names derived at Nix evaluation time with the component
dependency graph that Cabal writes during `Setup configure`.

This is a guardrail for the current prototype: the worker package environment is
still derived from nixpkgs Haskell dependency metadata, not from a complete
Cabal component context model.

### `dump-th-cross-unit-id-map-options`

Builds plugin options that map package identifiers appearing in raw Template
Haskell `NameG` payloads to target-side installed unit ids.

Usage:

```bash
dump-th-cross-unit-id-map-options HOST_GHC_PKG TARGET_GHC_PKG TARGET_PACKAGE_DB
```

It prints lines such as:

```text
unit-id-map=microlens-0.4.14.0=microlens-0.4.14.0-2EU...
unit-id-map=microlens-0.4.14.0-8xVr...=microlens-0.4.14.0-2EU...
```

The first form maps source package ids. The second maps host installed unit ids.
Both forms can appear in raw TH exact names, while `GHC.ThToHs` needs names that
resolve in the target package DB.
