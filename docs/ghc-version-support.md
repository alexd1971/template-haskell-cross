# GHC Version Support

This document tracks which GHC versions are known to work with the current raw
Template Haskell protocol and patches.

The active supported version is still GHC 9.10.3. Other versions below have
only been checked at the source-patch/API-shape level unless explicitly marked
otherwise.

## Current Matrix

| GHC | Source patch dry-run | API shape | Package build | Cross example build | Status |
| --- | --- | --- | --- | --- | --- |
| 9.8.4 | OK | Looks compatible | Not checked | Not checked | Candidate |
| 9.10.3 | OK | Compatible | Works | Works | Supported |
| 9.12.4 | OK | Looks compatible | Not checked | Not checked | Candidate |
| 9.14.1 | OK | Looks compatible | Not checked | Not checked | Candidate |

## What Was Checked

The following patch files were tested with `patch --dry-run -p1` against the
GHC source trees from the locked nixpkgs input:

- `nix/patches/ghc-9.10.3-export-runth.patch`
- `nix/patches/ghc-9.10.3-force-compiler-internal-interpreter.patch`
- `nix/patches/ghc-9.10.3-ignore-empty-th-finalizers.patch`

The checked GHC source attributes were:

- `pkgs.haskell.compiler.ghc984.src`
- `pkgs.haskell.compiler.ghc9103.src`
- `pkgs.haskell.compiler.ghc9124.src`
- `pkgs.haskell.compiler.ghc9141.src`

All three patches apply cleanly to all four source trees in the current locked
nixpkgs revision.

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

## Not Yet Checked

The patch dry-run result is not enough to declare support. Each candidate GHC
still needs:

- patched native worker GHC build;
- `th-cross-protocol` build;
- `th-cross-plugin` build;
- `th-host-worker` build;
- integration tests for raw TH splices;
- patched cross-GHC build for at least one target;
- example package build through `callPackageWithWorker`.

The Cabal bounds currently restrict the active packages to GHC 9.10.x:

```cabal
ghc >= 9.10 && < 9.11
ghc-boot >= 9.10 && < 9.11
```

That bound is intentional until build-level checks are done.

## Manual Build-Level Checks

The next step for a candidate version is to add a temporary Nix package-set
variant and let Nix build it. These builds may download large compiler closures
or build patched GHCs, so they are intentionally not part of the fast checks
yet.

For each candidate version:

1. Add native patched GHC derivation with the `export-runth` patch.
2. Add a matching target-side Haskell package set.
3. Temporarily widen Cabal bounds only for that candidate branch.
4. Build:

```bash
nix build .#host-ghc<VERSION>-worker -L
nix build .#target-ghc<VERSION>-plugin -L
```

5. Run plugin integration tests with the matching worker.
6. Add a cross-GHC derivation for at least one target and build:

```bash
nix build --no-write-lock-file ./examples/aeson -L
nix build --no-write-lock-file ./examples/microlens -L
```

Only after those checks pass should the Cabal bounds and public flake API be
expanded for that GHC version.

## Initial Assessment

The source-level result is better than expected: the current patches are not
obviously tied to GHC 9.10.3. The likely blockers for wider support are now:

- Cabal version bounds;
- renamed or moved GHC library dependencies;
- subtle type changes not visible from the symbol-level inspection;
- Nix package-set wiring for each GHC version;
- cross-GHC availability and bootstrap behavior in nixpkgs.
