# GHC Version Support

This document tracks which GHC versions are known to work with the current raw
Template Haskell protocol and patches.

The currently validated GHC versions are 9.8.4, 9.10.3, and 9.12.4. They all
use the raw Template Haskell protocol and the same public flake API.

## Current Matrix

| GHC | Source patch dry-run | API shape | Package build | Cross example build | Status |
| --- | --- | --- | --- | --- | --- |
| 9.8.4 | OK | Compatible | Works, integration retested | All examples work | Supported |
| 9.10.3 | OK | Compatible | Works, integration retested | All examples work | Supported |
| 9.12.4 | OK | Compatible | Works, integration retested | All examples work | Supported |
| 9.14.1 | Needs P4 adaptation | Changed `GHC.Tc.Types.TH` | Not checked | Not checked | Candidate |

## What Was Checked

The following patch files were tested with `patch --dry-run -p1` against the
GHC source trees from the locked nixpkgs input:

- `nix/patches/export-runth.patch`
- `nix/patches/force-compiler-internal-interpreter.patch`
- `nix/patches/ignore-empty-th-finalizers.patch`

The checked GHC source attributes were:

- `pkgs.haskell.compiler.ghc984.src`
- `pkgs.haskell.compiler.ghc9103.src`
- `pkgs.haskell.compiler.ghc9124.src`
- `pkgs.haskell.compiler.ghc9141.src`

P1 and P3 apply cleanly to all four source trees in the current locked nixpkgs
revision. P4 applies cleanly to 9.8.4, 9.10.3, and 9.12.4. GHC 9.14.1 changed
`GHC.Tc.Types.TH` enough that the raw `addTopDecls` type alias hunk needs a
version-specific adaptation.

The key GHC API shapes were also inspected in those source trees:

- `GHC.Types.Meta.MetaHook`
- `GHC.Types.Meta.MetaRequest`
- `GHC.Tc.Gen.Splice.defaultRunMeta`
- `GHC.Tc.Gen.Splice.runMeta'`
- `GHC.Tc.Gen.Splice.runTHExp`
- `GHC.Tc.Gen.Splice.qAddTopDecls`
- `GHC.Tc.Types.TcGblEnv.tcg_th_topdecls`
- `GHC.Tc.Utils.Monad.addModFinalizersWithLclEnv`

Those names and their broad shapes are present across 9.8.4, 9.10.3, 9.12.4,
and 9.14.1.

## Remaining Checks

The patch dry-run result is not enough to declare support. Each candidate GHC
still needs, except where explicitly recorded for a version:

- patched native worker GHC build;
- `th-cross-protocol` build;
- `th-cross-plugin` build;
- `th-host-worker` build;
- integration tests for raw TH splices;
- patched cross-GHC build for at least one target;
- example package build through `callPackageWithWorker`.

The Cabal bounds currently allow the validated compiler range:

```cabal
base >= 4.19 && < 4.22
ghc >= 9.8 && < 9.13
ghc-boot >= 9.8 && < 9.13
```

Those bounds cover GHC 9.8.4, 9.10.3, and 9.12.4. GHC 9.14.x is intentionally
outside the range until its patch compatibility is checked and fixed.

Current remaining work:

- GHC 9.14.1: adapt the P4 patch hunk for the changed `GHC.Tc.Types.TH` source
  layout before attempting worker/plugin builds.
- Cabal bounds: widen beyond `< 9.13` only after a newer GHC is backed by
  worker/plugin/integration/example checks.

## Compiler Profiles

The flake exposes explicit compiler profiles instead of creating a new top-level
package output for each GHC version:

```text
lib.${system}.compilerProfiles
lib.${system}.mkCompilerForVersion
lib.${system}.mkCompilerFromProfile
lib.${system}.compilers.ghc9124
```

Each profile records the GHC version, nixpkgs package-set name, compiler
configuration file, and the worker/cross patch file lists to apply from
`nix/patches`. `mkCompilerForVersion` selects one of those profiles by version.
The result contains the patched worker GHC, host and target package sets, the
worker executable, the target plugin, and a target `ghcWithPackages` containing
the plugin. The worker libdir version is derived from the selected GHC
derivation, not passed as a separate string.

The cross-GHC `--export-dynamic` change is a Hadrian flag rather than a patch
file, so it remains in the cross-GHC derivation next to the target-specific
compiler wiring.

Profiles can opt into Nix-side Cabal jailbreaks for local investigation. The
intended lifecycle for a new GHC version is:

1. Add a compiler profile with `jailbreak = true`.
2. Run worker, plugin, integration, and cross-example checks.
3. If the checks pass, widen the source `.cabal` bounds.
4. Remove `jailbreak = true` from the profile.

Currently validated profiles build against the source `.cabal` bounds directly.
The `th-cross-nix-tool` executable is built per compiler profile because the
context validator reads Cabal's `dist/setup-config`; that persisted file is an
internal Cabal format and must be read by a compatible Cabal library version.

The following eval checks pass:

```bash
nix eval .#lib.x86_64-linux.compilers.ghc9124.targetProtocol.drvPath
nix eval .#lib.x86_64-linux.compilers.ghc9124.targetPlugin.drvPath
nix eval .#lib.x86_64-linux.compilers.ghc9124.hostWorker.drvPath
nix eval .#lib.x86_64-linux.compilers.ghc9124.patchedGhc.drvPath
```

The following build checks pass for 9.8.4, 9.10.3, and 9.12.4:

```bash
version=9.12.4
nix build --impure --expr 'let f = builtins.getFlake "path:'"$PWD"'"; p = f.lib.x86_64-linux.mkCompilerForVersion "'"$version"'"; in p.hostWorker' -L
nix build --impure --expr 'let f = builtins.getFlake "path:'"$PWD"'"; p = f.lib.x86_64-linux.mkCompilerForVersion "'"$version"'"; in p.targetPlugin' -L
nix build --impure --expr 'let f = builtins.getFlake "path:'"$PWD"'"; p = f.lib.x86_64-linux.mkCompilerForVersion "'"$version"'"; in p.targetGhcWithPlugin' -L
```

The matching protocol package is covered as a dependency of both worker and
plugin builds.

The full integration test suite passes with the 9.8.4, 9.10.3, and 9.12.4
compiler profiles from `nix develop`:

```bash
TH_CROSS_GHC_VERSION=<VERSION> \
th-cross-test
```

For a single test:

```bash
TH_CROSS_GHC_VERSION=<VERSION> \
th-cross-test -p '/worker expression splice/'
```

`th-cross-test` uses compiler-specific Cabal paths such as
`.cabal-store-nix-ghc-9.12.4` and `dist-newstyle-nix-ghc-9.12.4`. This avoids
mixing Cabal plans and installed package IDs between different GHC builds that
share the same numeric version.

When `TH_CROSS_GHC_VERSION` is set, `th-cross-test` builds the matching
target `ghcWithPackages` from the compiler profile and passes Cabal absolute
paths to its `ghc` and `ghc-pkg`. The corresponding `ghc-<VERSION>` executables
do not need to already exist in `PATH`.

## Manual Version Checks

Compiler profiles avoid adding a new top-level flake output for every candidate
GHC. These builds may download large compiler closures or build patched GHCs, so
they are intentionally not part of the fast checks yet.

For each candidate version:

1. Add or select a compiler profile in `nix/flake/ghc-profiles.nix`. Use
   `jailbreak = true` only while evaluating a version outside the current
   source `.cabal` bounds.
2. Build the profile worker, plugin, and target compiler wrapper:

```bash
version=9.12.4
nix build --impure --expr 'let f = builtins.getFlake "path:'"$PWD"'"; p = f.lib.x86_64-linux.mkCompilerForVersion "'"$version"'"; in p.hostWorker' -L
nix build --impure --expr 'let f = builtins.getFlake "path:'"$PWD"'"; p = f.lib.x86_64-linux.mkCompilerForVersion "'"$version"'"; in p.targetPlugin' -L
nix build --impure --expr 'let f = builtins.getFlake "path:'"$PWD"'"; p = f.lib.x86_64-linux.mkCompilerForVersion "'"$version"'"; in p.targetGhcWithPlugin' -L
```

3. Run plugin integration tests with the matching worker:

```bash
TH_CROSS_GHC_VERSION="$version" \
th-cross-test
```

4. Add or select a patched cross-GHC derivation for at least one target and
   build all example packages:

```bash
TH_CROSS_GHC_VERSION="$version" TH_CROSS_TARGET=aarch64-linux nix build --impure --no-write-lock-file ./examples/aeson -L
TH_CROSS_GHC_VERSION="$version" TH_CROSS_TARGET=aarch64-linux nix build --impure --no-write-lock-file ./examples/executable -L
TH_CROSS_GHC_VERSION="$version" TH_CROSS_TARGET=aarch64-linux nix build --impure --no-write-lock-file ./examples/microlens -L
TH_CROSS_GHC_VERSION="$version" TH_CROSS_TARGET=aarch64-linux nix build --impure --no-write-lock-file ./examples/target-context -L
```

Only after those checks pass should the Cabal bounds and public flake API be
expanded for that GHC version. Once the bounds are expanded, remove
`jailbreak = true` from that profile.

## Initial Assessment

The source-level result is better than expected: the current patches are not
obviously tied to GHC 9.10.3. The likely blockers for wider support are now:

- Cabal version bounds;
- renamed or moved GHC library dependencies;
- subtle type changes not visible from the symbol-level inspection;
- Nix package-set wiring for each GHC version;
- cross-GHC availability and bootstrap behavior in nixpkgs.
