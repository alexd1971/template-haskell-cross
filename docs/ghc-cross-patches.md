# GHC Patches for Cross TH

This document describes the GHC changes required by the current cross TH
prototype. There are two affected compilers:

- the aarch64 cross-GHC, which must load a native plugin through
  `-fplugin-library` and continue without a target interpreter;
- the native worker GHC, which must expose raw Template Haskell runner APIs and
  capture raw `addTopDecls` payloads.

Target: GHC 9.10.3 producing `aarch64-linux` binaries.
The patches live in `nix/patches/`.

---

## Context

Cross-GHC can evaluate Template Haskell, but it requires a remote
target interpreter (iserv) running on the target device or emulator.
The TH cross architecture avoids this complexity by evaluating splices
on the build host instead:

1. loading a **native plugin** into the cross-GHC process via
   `-fplugin-library`;
2. the plugin intercepts `runMetaHook` and delegates splice evaluation
   to a **native host worker** built with a compatible patched GHC 9.10.3;
3. the worker returns binary-encoded Template Haskell AST values;
4. the cross compiler converts them locally and continues normal
   compilation.

Plain nixpkgs cross-GHC needs P1-P3 for this flow. The native worker GHC needs
P4.

---

## P1 — Force `HAVE_INTERNAL_INTERPRETER`

**File**: `nix/patches/ghc-9.10.3-force-compiler-internal-interpreter.patch`

**What**: Changes `compiler/ghc.cabal.in` to define
`-DHAVE_INTERNAL_INTERPRETER` unconditionally instead of gating behind
`if flag(internal-interpreter)`.

**Why a patch rather than a build flag**.  Three simpler approaches
failed:

- Hadrian `--flags=internal-interpreter` via `cabal.configure.opts`:
  Hadrian computes package flags separately and appends its own final
  `--flags=...`, overriding the user setting.
- Patch `hadrian/src/Settings/Packages.hs` to force the flag: nixpkgs
  uses a prebuilt `hadrian` from `nativeBuildInputs`; patching the
  source copy does not affect the already-compiled builder.
- Hadrian `stage1.ghc.ghc.hs.opts += -DHAVE_INTERNAL_INTERPRETER`:
  the installed cross compiler is built in Hadrian's stage0 context,
  so stage1 settings do not reach it.

The only reliable way is to patch `compiler/ghc.cabal.in` directly.

**Why it is needed at all**: `GHC.Driver.Plugins.loadExternalPlugins`
is wrapped in `#if defined(HAVE_INTERNAL_INTERPRETER)`.  Without the
macro, any non-empty `-fplugin-library` argument causes:

```
loadExternalPlugins: can't load external plugins with GHC built
without internal interpreter
```

The cross compiler does not need a target interpreter (TH evaluation is
delegated to the host worker), but `loadExternalPlugins` currently
conflates "can load plugins" with "has an interpreter".

**Can this be contributed to GHC?**  The proper fix is to decouple the
two concepts in `GHC.Driver.Plugins` — a cross compiler should be able
to `dlopen` a native plugin even without target interpreter support.
The current patch forces the macro as a pragmatic shortcut, but the
real fix requires design work in GHC upstream.

---

## P2 — `--export-dynamic` on stage0 `ghc-bin`

**Where**: Hadrian flag in `nix/flake/cross-ghc/ghc9103-aarch64.nix`:

```
stage0.ghc-bin.ghc.link.opts += -optl-Wl,--export-dynamic
```

**What**: Links the stage0 `ghc-bin` executable with exported dynamic
symbols.

**Why**: The cross-GHC is statically linked.  The plugin shared object
loaded via `dlopen` depends on RTS symbols (`stg_gc_unpt_r1`, etc.).
These symbols exist in the normal symbol table of the cross-GHC binary
but are absent from the dynamic symbol table.  `--export-dynamic` makes
them visible to `dlopen`.

In cross builds Hadrian copies `stage0/bin/ghc → stage1/bin/ghc`, so
the flag must be applied to stage0.

**Can this be contributed to GHC?**  `iserv` already receives the same
flag through Hadrian.  This should be a one-line Hadrian change.

---

## P3 — Empty `ThModFinalizers` are no-ops

**File**: `nix/patches/ghc-9.10.3-ignore-empty-th-finalizers.patch`

**What**: Adds a guard at the top of
`GHC.Tc.Utils.Monad.addModFinalizersWithLclEnv`:

```haskell
addModFinalizersWithLclEnv (ThModFinalizers []) = pure ()
```

**Why**: After the plugin returns a splice result, GHC unconditionally
calls `addModFinalizersWithLclEnv (ThModFinalizers [])`.  Later,
`runRemoteModFinalizers` calls `tcGetInterp` before checking whether
the finalizer list is empty.  `tcGetInterp` fails on a cross compiler
that has no interpreter:

```
Template haskell requires a target code interpreter
```

Short-circuiting the empty case avoids the interpreter check
altogether.

**Can this be contributed to GHC?**  This is a standalone bugfix: an
empty finalizer list should never require an interpreter.  Can be
submitted independently of the TH cross work.

---

## P4 — Export raw TH runners and capture raw `addTopDecls`

**File**: `nix/patches/ghc-9.10.3-export-runth.patch`

**Applies to**: native patched worker GHC (`packages.*.patched-ghc9103`), not
the aarch64 cross-GHC derivation.

**What**:

- exports `runTHExp`, `runTHPat`, `runTHType`, and `runTHDec` from
  `GHC.Tc.Gen.Splice`;
- adds `tcg_th_topdecls_th :: TcRef [TH.Dec]` to `TcGblEnv`;
- initializes that ref in `GHC.Tc.Utils.Monad.initTc`;
- records the original `[TH.Dec]` payload in `qAddTopDecls`.

**Why**: The worker needs to stop after host-side TH execution and return raw
Template Haskell AST values. Pretty-printed Haskell is not a reliable transport
format for exact names or references to entities from hidden/internal modules.
Capturing raw `addTopDecls` payloads removes the remaining textual replay path.

**Can this be contributed to GHC?**  The export-list part is a small API
exposure. The additional raw `addTopDecls` ref is prototype-specific unless
GHC grows a supported hook for observing TH side effects before conversion.

---

## Usage

The patched native worker GHC is exposed as:

```bash
nix build .#patched-ghc9103
```

The patched cross-GHC is exposed as:

```bash
nix build .#cross-ghc9103-aarch64-linux
```

The derivation's `passthru.crossPatchNotes` contains structured metadata about
the cross-GHC patches P1-P3.

Cross-compilation of packages using this GHC is demonstrated in the
experiment packages:

```bash
nix build .#consumer-ghc9103-cross-target-context-package
nix build .#consumer-ghc9103-cross-microlens-package  # with microlens-th
nix build .#consumer-ghc9103-cross-aeson-package      # with aeson TH
nix build .#consumer-ghc9103-cross-executable-package # executable + qemu
```
