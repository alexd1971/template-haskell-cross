# Browser-oriented WASM research

This note records the current state of the WASM investigation. The goal is not
just to produce a `wasm32` object file, but to make a Haskell bundle callable
from browser JavaScript so that it can eventually be used from Flutter Web.

## Target requirement

For `flutter-haskell-bridge` Web support the useful artifact shape is:

- a browser-loadable Haskell bundle, most likely `.wasm` plus JavaScript glue;
- a stable JavaScript/Dart-callable API boundary;
- initialization that can run in a browser environment without a native process;
- no dependency on a local Nix store or native dynamic libraries at runtime.

That requirement makes plain WASI only partially relevant. WASI is a system
interface for WebAssembly modules, not a browser API by itself. A browser can
run WASI modules only through an additional WASI runtime/polyfill layer, and
that layer would become part of the integration contract.

## Attempted path: generic `wasm32-unknown-wasi` cross-GHC

The first experiment tried to add a new `wasm32-wasi` target profile using
`pkgs.pkgsCross.wasi32` and the existing `th-cross` cross-GHC machinery.

This reached several independent blockers.

### GMP is not a good default for WASI

The target GMP build failed against `wasilibc` because `signal.h` intentionally
errors unless signal emulation is enabled:

```text
wasm lacks signal support; to enable minimal signal emulation,
compile with -D_WASI_EMULATED_SIGNAL and link with -lwasi-emulated-signal
```

The practical workaround was to switch GHC to `native-bignum` for this target.
That avoids making GMP part of the WASI compiler bootstrap.

### libffi assumes Emscripten for wasm32

Both standalone target `libffi` and GHC's bundled `libffi` selected wasm32 code
that includes:

```c
#include <emscripten/emscripten.h>
```

That is not available in a pure WASI toolchain. Disabling target `libffi` in the
Nix package set was straightforward, but GHC still tried to build its bundled
copy for runtime adjustors.

Passing `--disable-libffi-adjustors` was not sufficient on its own. The GHC
configure logic did not cleanly distinguish an explicit disabled value from
auto-detection, and Hadrian still reached a path that built bundled `libffi`.

The experiment used two workarounds:

- patch GHC's configure/toolchain logic so an explicit disabled adjustor setting
  is represented;
- replace the bundled `libffi` wasm32 source in the unpacked GHC tree with
  minimal stubs, avoiding the Emscripten header.

That was enough to get past the bundled `libffi` build, but it is not a clean
long-term solution.

### Object merging check fails for WASI objects

GHC's configure check for the object-merging linker path failed:

```text
wasm32-unknown-wasi-ld: error: conftesta.o: unknown file type
configure: error: ... could not merge objects
```

The experiment bypassed this by setting an empty `MergeObjsCmd`. This is
acceptable as an investigation step, but it needs proper validation before it
can be considered a supported target configuration.

### GHC 9.10.3 lacks a WASI LLVM target entry

After the earlier blockers were bypassed, the compiler failed while compiling
boot libraries:

```text
Failed to lookup LLVM data layout
Target: wasm32-unknown-wasi
```

The experiment added a `wasm32-unknown-wasi` LLVM target entry using the data
layout reported by clang 21:

```text
e-m:e-p:32:32-p10:8:8-p20:8:8-i64:64-i128:128-n32:64-S128-ni:1:10:20
```

This moved the build forward, but exposed a deeper backend issue.

### The regular GHC LLVM backend emits non-C calling conventions

The next failure came from LLVM lowering:

```text
WebAssembly doesn't support non-C calling conventions
WebAssembly doesn't support language-specific or target-specific calling conventions yet
```

The failing command was compiling `ghc-prim` with the cross-GHC. The important
point is that the normal GHC LLVM backend emits GHC-specific calling
conventions, while WebAssembly currently accepts only the C calling convention
in this path.

An experimental patch forcing the LLVM backend to use the C calling convention
for `ArchWasm32` was considered, but this is not just a mechanical build fix:
it changes assumptions at the RTS/code-generation boundary and would require
deep validation.

## Current conclusion

The generic `pkgsCross.wasi32` route is not the best immediate path for
browser/Flutter Web support.

It is still useful research because it identified concrete integration points:

- `native-bignum` is likely required or at least strongly preferable for WASM;
- target `libffi`/adjustors need to be avoided or handled by a wasm-aware path;
- GHC's normal LLVM backend is not enough by itself for wasm32 in this setup;
- the browser runtime contract is separate from the WASI target triple.

The current experimental changes were preserved outside the main working tree
as a Git stash:

```text
stash@{0}: research wasm32-wasi ghc experiment
```

If this path becomes relevant again, recover it into a separate branch before
continuing:

```bash
git switch -c research/wasm32-wasi
git stash apply stash@{0}
```

## Recommended next direction

The next investigation should start from a small browser-oriented toy project
instead of from the full cross-GHC bootstrap.

The toy project should answer these questions in order:

1. What browser-side artifact shape do we want for `flutter-haskell-bridge`?
   For example: `.wasm` plus JS loader, one initialization function, exported
   functions callable from Dart JS interop.
2. Can we build and load a minimal wasm module with the same host-side contract
   that Flutter Web would use?
3. Which Haskell compiler path can produce that artifact shape?
   Candidates to evaluate:
   - GHC's wasm backend, if available in the selected GHC/nixpkgs set;
   - an Emscripten-oriented path, because browser glue is first-class there;
   - GHCJS/JavaScript as a fallback if the wasm route is not yet practical.
4. Once the browser contract is validated, integrate Template Haskell support
   into that path.

This keeps the research aligned with the actual product requirement: a Haskell
bundle callable from Flutter Web, not merely a successful `wasm32-wasi` compiler
build.
