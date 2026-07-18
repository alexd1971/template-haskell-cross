# Plain nixpkgs Cross GHC Investigation

This document records the first investigation of using plain nixpkgs as the
cross-GHC provider for the TH cross prototype.

## Scope

The target checked here is:

```text
pkgsCross.aarch64-multiplatform
```

on an `x86_64-linux` host.

This is intentionally not Android yet. The goal is to determine whether plain
nixpkgs can provide the basic pieces before adding Android-specific toolchain
complexity.

## Platform Split

The plain nixpkgs cross package set has the expected platform split:

```bash
nix eval --raw \
  nixpkgs#legacyPackages.x86_64-linux.pkgsCross.aarch64-multiplatform.stdenv.buildPlatform.config

nix eval --raw \
  nixpkgs#legacyPackages.x86_64-linux.pkgsCross.aarch64-multiplatform.stdenv.hostPlatform.config
```

Observed result:

```text
buildPlatform=x86_64-unknown-linux-gnu
hostPlatform=aarch64-unknown-linux-gnu
```

The native build side is also available:

```bash
nix eval --raw \
  nixpkgs#legacyPackages.x86_64-linux.pkgsCross.aarch64-multiplatform.buildPackages.haskell.compiler.ghc984.version
```

Observed result:

```text
9.8.4
```

This is suitable for building or running a native host-side worker.

## Target-Side GHC Availability

The critical question is whether the cross Haskell package set can provide GHC
9.8.4. This compiler executable runs on the build platform and emits code for
the target platform.

```bash
nix eval --raw \
  nixpkgs#legacyPackages.x86_64-linux.pkgsCross.aarch64-multiplatform.haskell.compiler.ghc984.version
```

Observed result:

```text
error: GHC >= 9.6 can't be cross-compiled. If you meant to build a GHC cross-compiler, use `buildPackages`.
```

The same error appears for cross GHC 9.6 and later in the checked plain nixpkgs
set.

Checked versions:

```text
ghc810  removed from nixpkgs
ghc90   removed from nixpkgs
ghc92   removed from nixpkgs
ghc94   cross GHC evaluates to 9.4.8
ghc948  cross GHC evaluates to 9.4.8
ghc96   rejected: GHC >= 9.6 can't be cross-compiled
ghc98   rejected: GHC >= 9.6 can't be cross-compiled
ghc984  rejected: GHC >= 9.6 can't be cross-compiled
ghc910  rejected: GHC >= 9.6 can't be cross-compiled
ghc9103 rejected: GHC >= 9.6 can't be cross-compiled
```

## Effect On This Prototype

Only the host worker is intentionally tied to GHC 9.8.4:

```text
th-host-worker:
  ghc == 9.8.4
```

The consumer/cross compiler does not have to be GHC 9.8.4. The protocol sends
textual Haskell fragments, so the consumer compiler should parse the returned
fragment with its own parser. This is the reason cross-version tests with a GHC
9.8.4 worker and a GHC 9.10.3 consumer are useful.

The current `THCross.Plugin` package is still limited to GHC 9.8 through GHC
9.10:

```text
th-cross-plugin:
  ghc >= 9.8 && < 9.11
```

Therefore the available plain nixpkgs target-side `ghc948` path is not directly
usable by the current plugin code, but it is a valid candidate for testing the
cross side of the textual protocol. To use it, the consumer-side plugin needs a
GHC 9.4.8 compatibility path while the host worker can remain on GHC 9.8.4.

## Current Repository Probe

`flake.nix` exposes:

```text
packages.x86_64-linux.aarch64-linux-cross-probe
checks.x86_64-linux.cross-target-probe-aarch64-linux
```

Run:

```bash
nix build .#aarch64-linux-cross-probe
cat result
```

Expected output:

```text
buildPlatform=x86_64-unknown-linux-gnu
targetHostPlatform=aarch64-unknown-linux-gnu
nativeHostGhc=9.8.4
crossGhc948=9.4.8
crossGhc984Status=unsupported by plain nixpkgs cross set: GHC >= 9.6 can't be cross-compiled here
nextStep=use haskell.nix or another cross-GHC provider for a real targetHaskellPkgs
```

## Conclusion

Plain nixpkgs is useful for documenting the host/target split and for providing
native `buildPackages` tools, including GHC 9.8.4 for the host worker.

Plain nixpkgs does not currently provide cross GHC 9.8.4 for
`pkgsCross.aarch64-multiplatform`, but it does provide a cross GHC 9.4.8
candidate.

The next step should not be a full haskell.nix migration by default. Instead,
investigate whether the consumer-side plugin can support GHC 9.4.8, while
keeping the existing GHC 9.8.4 host worker, protocol, and worker wiring
unchanged.

See `docs/ghc-9.4.8-consumer-plugin.md` for the first consumer-side GHC 9.4.8
API check. The plugin library now builds natively with GHC 9.4.8 through:

```bash
nix build .#th-cross-plugin-ghc948
```

The next step is a native GHC 9.4.8 plugin smoke test against the existing GHC
9.8.4 host worker, before trying the target-side
`pkgsCross.aarch64-multiplatform.haskell.packages.ghc948` path.
