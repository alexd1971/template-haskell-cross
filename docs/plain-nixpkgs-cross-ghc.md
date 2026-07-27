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

## Legacy Effect On This Prototype

This section describes the original textual-protocol prototype. It is retained
for historical context only.

At that point only the host worker was intentionally tied to GHC 9.8.4:

```text
th-host-worker:
  ghc == 9.8.4
```

The consumer/cross compiler did not have to be GHC 9.8.4 because the legacy
protocol sent textual Haskell fragments and asked the consumer compiler to parse
the returned fragment with its own parser. This was the reason cross-version
tests with a GHC 9.8.4 worker and a GHC 9.10.3 consumer were useful.

The current implementation no longer follows that path. The active plugin and
worker are GHC 9.10.x only:

```text
th-cross-plugin:
  ghc >= 9.10 && < 9.11
```

The available plain nixpkgs target-side `ghc948` path is therefore no longer a
candidate for the active raw protocol. It remains relevant only for reading the
legacy textual experiment.

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
targetSideGhc948Compiler=ghc-aarch64-unknown-linux-gnu-9.4.8
buildHostCrossGhc948Compiler=aarch64-unknown-linux-gnu-ghc-9.4.8
consumerPluginShape=native build-host plugin built by consumer-ghc948-plugin
crossGhc984Status=unsupported by plain nixpkgs cross set: GHC >= 9.6 can't be cross-compiled here
nextStep=run consumer-ghc948-cross-worker-smoke to test cross-GHC plus native same-version plugin plus GHC 9.8.4 worker
```

## Conclusion

Plain nixpkgs is useful for documenting the host/target split and for providing
native `buildPackages` tools, including GHC 9.8.4 for the host worker.

Plain nixpkgs does not currently provide cross GHC 9.8.4 for
`pkgsCross.aarch64-multiplatform`, but it does provide a cross GHC 9.4.8
candidate.

This early probe led to two branches:

- GHC 9.4.8 is a useful plain-nixpkgs baseline, but its tested binary does not
  expose `-fplugin-library` and the normal `-fplugin` path blocks before
  `runMetaHook`;
- GHC 9.10.3 plus a small patched cross-GHC derivation now provides the current
  successful path for `-fplugin-library`, the host worker smoke, the manual
  Cabal package smoke, and a nixpkgs Haskell generic-builder package build.

The current successful Nix path is documented in `docs/nix-integration.md`.

See `docs/cross-version.md` for the GHC 9.4.8
API check. The plugin library now builds natively with GHC 9.4.8 through:

```bash
nix build .#consumer-ghc948-plugin
```

The native GHC 9.4.8 smoke test now passes with the existing GHC 9.8.4 host
worker. The next cross-target question is more specific than "can the package
build?": a GHC plugin must be loadable by the cross-GHC process running on the
build host.

That means the plugin should be native to the build host, but compiled against
the same GHC API version as the cross compiler:

```text
x86_64-linux THCross.Plugin built with GHC 9.4.8
  + aarch64-producing cross-GHC 9.4.8
  + x86_64-linux th-host-worker built with GHC 9.8.4
```

The flake exposes this as an explicit smoke package:

```bash
nix build .#consumer-ghc948-cross-worker-smoke -L
```

There is also a no-Template-Haskell variant that keeps the plugin enabled:

```bash
nix build .#consumer-ghc948-cross-plugin-no-th-smoke -L
```

It is intentionally not included in the default `checks`, because it can pull in
the full plain-nixpkgs aarch64 cross-GHC 9.4.8 closure.

Current status: the correct compiler executable comes from
`pkgsCross.aarch64-multiplatform.buildPackages.haskell.compiler.ghc948`, not
from `pkgsCross.aarch64-multiplatform.haskell.compiler.ghc948`.

That executable is `x86-64` and reports:

```text
("cross compiling","YES")
```

The remaining blocker is GHC 9.4's interpreter setup before the custom
`runMetaHook` is reached. A control compile of `NoTH.hs` without `-fplugin`
succeeds with `-fno-external-interpreter`, but compiling the same module with
`THCross.Plugin` enabled fails with:

```text
Couldn't find a target code interpreter. Try with -fexternal-interpreter
```

but enabling the external interpreter conflicts with plugins:

```text
Plugins require -fno-external-interpreter
```

This means the problem is not specific to TH splice execution. In this plain
nixpkgs GHC 9.4 cross setup, enabling a GHC plugin is already enough to require
a target code interpreter.

## GHC 9.4 Plugin Loading Blocker

The failure happens before `THCross.Plugin` can install or use `runMetaHook`.
The dynamic plugin failure is visible from the installed GHC 9.4.8 binary:

```text
--show-options does not list -fplugin-library
strings .../bin/ghc contains fplugin/fplugin-opt/fplugin-trustworthy,
  but not fplugin-library or ExternalPlugin
```

The related source paths observed in newer GHC sources available in the Nix
store are:

```text
/nix/store/x74jagfaidi2gxwy01737im9mcvb31yh-ghc-a340115/compiler/GHC/Runtime/Loader.hs
/nix/store/x74jagfaidi2gxwy01737im9mcvb31yh-ghc-a340115/compiler/GHC/Driver/Env.hs
/nix/store/x74jagfaidi2gxwy01737im9mcvb31yh-ghc-a340115/compiler/GHC/Tc/Gen/Splice.hs
```

That source tree is GHC 9.8.4 (`configure.ac` reports `AC_INIT(... 9.8.4)`),
so it must not be treated as exact source for the tested GHC 9.4.8 cross
compiler. It is still useful for understanding the later dynamic/external
plugin architecture.

The important functions for the dynamic plugin failure are:

```text
GHC.Runtime.Loader.loadPlugins
GHC.Runtime.Loader.checkExternalInterpreter
GHC.Runtime.Loader.getValueSafely
GHC.Driver.Env.hscInterp
GHC.Tc.Gen.Splice.runMeta
GHC.Tc.Gen.Splice.tcGetInterp
```

In the later source, the dynamic plugin path in
`GHC.Runtime.Loader.loadPlugins` checks interpreter configuration before loading
plugin modules. Non-empty dynamic plugins call `checkExternalInterpreter`.

`checkExternalInterpreter` rejects `-fexternal-interpreter` for plugins:

```text
Plugins require -fno-external-interpreter
```

With `-fno-external-interpreter`, `GHC.Runtime.Loader.getValueSafely` still uses
`hscInterp hsc_env` to load the plugin value. For this cross-GHC, `hsc_interp`
is absent, so `GHC.Driver.Env.hscInterp` fails with:

```text
Couldn't find a target code interpreter. Try with -fexternal-interpreter
```

The Template Haskell path has its own interpreter check in
`GHC.Tc.Gen.Splice.tcGetInterp`, but the current failure is earlier than that.
This is why the no-TH smoke test with `-fplugin=THCross.Plugin` fails the same
way as the splice smoke test.

## Possible Workarounds

### External Static Plugin Library

Some GHC source trees have a command-line mechanism intended for this exact
class of cross-compiler problem:

```bash
-fplugin-library=path/to/plugin;package-unit-id;THCross.Plugin;["worker=/path/to/th-host-worker"]
```

The source is:

```text
GHC.Driver.Plugins.External
GHC.Driver.Session.addExternalPlugin
GHC.Driver.Session flag: fplugin-library
GHC.Runtime.Loader.initializePlugins
GHC.Driver.Plugins.loadExternalPlugins
```

`GHC.Driver.Plugins.External` describes two static plugin forms:

```text
internal: installed through the GHC API
external: loaded from a shared library through -fplugin-library
```

The same module explicitly says the intended use case for external static
plugins is cross compilers, because a GHC cross-compiler cannot build or load
host plugins through the non-static `-fplugin` path.

This would be the preferred practical route before patching GHC, but not with
the tested GHC 9.4.8 binary:

```text
obtain a cross-GHC version that exposes -fplugin-library
  -> build THCross.Plugin as a build-host shared library for the same GHC API
  -> pass that library to cross-GHC with -fplugin-library
  -> keep the same GHC 9.8.4 th-host-worker
  -> check whether NoTH.hs reaches successful compilation
  -> then check whether Example.hs reaches runMetaHook and the worker
```

Important constraints from the GHC source comment:

```text
the plugin library must target the same compiler ABI;
the unit id must be known and passed in the -fplugin-library spec;
the symbol looked up is THCrossziPlugin_plugin_closure, optionally prefixed by the encoded unit id;
the plugin value type is not checked, so a wrong library/symbol can crash the compiler.
```

This path still loads a host `.so`, but it should bypass the dynamic
module/interface loading path used by `-fplugin=THCross.Plugin`. That is exactly
the path that is currently blocked by `hscInterp`.

However, the currently tested plain-nixpkgs cross-GHC 9.4.8 binary does not
appear to expose this flag:

```bash
/nix/store/...-aarch64-unknown-linux-gnu-ghc-9.4.8/bin/aarch64-unknown-linux-gnu-ghc \
  --show-options | grep plugin
```

Observed plugin-related options:

```text
-plugin-package-id
-plugin-package
-hide-all-plugin-packages
-fplugin-opt
-fplugin-trustworthy
-fplugin
-fclear-plugins
```

Manual use of `-fplugin-library=...` was parsed as `-fplugin` with a module name
starting with `-library=...`, not as an external static plugin flag:

```text
Could not find module '-library=/nix/store/...'
```

So this remains a potential route for a GHC that exposes `-fplugin-library`, but
it is not currently available in the tested plain-nixpkgs GHC 9.4.8 cross
compiler.

The next investigation should therefore be:

```text
find/build a cross-GHC version that supports -fplugin-library;
verify the flag in the actual binary with --show-options;
compile THCross.Plugin with a native GHC of the same version;
run the existing NoTH.hs and Example.hs smokes with -fplugin-library.
```

If this works, it is preferable to patching GHC. It preserves the plugin as an
ordinary separately built artifact and uses GHC's intended external static
plugin mechanism for cross compilers.

Plain nixpkgs does provide a build-host aarch64-producing GHC 9.10.3 executable:

```bash
nix build --no-link --print-out-paths \
  nixpkgs#legacyPackages.x86_64-linux.pkgsCross.aarch64-multiplatform.buildPackages.haskell.compiler.ghc9103
```

The resulting binary reports:

```text
("Project version","9.10.3")
("Host platform","x86_64-unknown-linux")
("Target platform","aarch64-unknown-linux")
("cross compiling","YES")
```

and exposes:

```text
-fplugin-library
```

However, the first `NoTH.hs` `-fplugin-library` smoke still fails:

```text
loadExternalPlugins: can't load external plugins with GHC built without internal interpreter
```

This is a different blocker than GHC 9.4.8:

```text
GHC 9.4.8:  -fplugin-library is absent from the tested binary.
GHC 9.10.3: -fplugin-library is present, but loadExternalPlugins was compiled
            without HAVE_INTERNAL_INTERPRETER.
```

The flake records this as:

```bash
nix build .#consumer-ghc9103-cross-plugin-library-probe -L
cat result
```

The next preferred path is therefore more specific: build a cross-GHC version
that both exposes `-fplugin-library` and includes the internal interpreter
support required by `loadExternalPlugins`. The flake contains a temporary
experimental output for this:

```bash
nix build .#consumer-ghc9103-cross-ghc-bootstrapped -L
nix build .#consumer-ghc9103-cross-plugin-library-bootstrapped-probe -L
cat result
```

This variant overrides the GHC 9.10.3 cross compiler to bootstrap with native
GHC 9.10.3 instead of the plain nixpkgs GHC 9.8.4 bootstrap. This confirms the
same-version bootstrap shape:

```text
("Booter version","9.10.3")
("Stage","1")
("cross compiling","YES")
```

However, this is not sufficient for the tested nixpkgs GHC 9.10.3 cross
derivation. The `-fplugin-library` probe still fails in
`GHC.Driver.Plugins.loadExternalPlugins`:

```text
loadExternalPlugins: can't load external plugins with GHC built without internal interpreter
```

The source-level reason is visible in the GHC 9.10.3 source used by nixpkgs:

```text
compiler/GHC/Driver/Plugins.hs
compiler/ghc.cabal.in
ghc/ghc-bin.cabal.in
hadrian/src/Settings/Packages.hs
```

`GHC.Driver.Plugins.loadExternalPlugins` is compiled in the `compiler` package.
If `HAVE_INTERNAL_INTERPRETER` is not defined, the non-empty
`-fplugin-library` path panics before attempting to load the plugin:

```text
loadExternalPlugins: can't load external plugins with GHC built without internal interpreter
```

The macro comes from the Cabal flag:

```text
compiler/ghc.cabal.in:
  if flag(internal-interpreter)
      CPP-Options: -DHAVE_INTERNAL_INTERPRETER
```

Hadrian also has an `internal-interpreter` flag path for `ghc-bin`. In the
checked source, the automatic Hadrian condition for both `compiler` and
`ghc-bin` is:

```text
ghcWithInterpreter && notStage0
```

The same-version bootstrap cross workaround found in `Settings/Packages.hs`
applies to the `ghci` package:

```text
cross && bootCross -> -finternal-interpreter
```

That explains the observed result: rebuilding with native GHC 9.10.3 as the
bootstrap compiler can satisfy the `ghci` workaround, but it does not by itself
force `HAVE_INTERNAL_INTERPRETER` into the installed stage1 `compiler` package
where `loadExternalPlugins` lives.

The flake now exposes a second experiment that tries to force the relevant
Hadrian/Cabal configuration:

```bash
nix build .#consumer-ghc9103-cross-plugin-library-forced-internal-interpreter-probe -L
cat result
```

The first version of this experiment used Hadrian command-line settings
conceptually equivalent to:

```text
stage1.ghc.cabal.configure.opts += --flags=internal-interpreter
stage1.ghc-bin.cabal.configure.opts += --flags=internal-interpreter
```

The build log showed those settings were passed to Hadrian, but the installed
cross-GHC still failed with the same `loadExternalPlugins` panic. The likely
reason is that `cabal.configure.opts` contributes to Hadrian's `Cabal Setup`
arguments, while Hadrian computes package flags separately through `Cabal
Flags` and appends its own final `--flags=...` argument.

The second version of this experiment patched `hadrian/src/Settings/Packages.hs`
inside the GHC source tree. It changed the existing condition for the
`internal-interpreter` Cabal flag from:

```text
ghcWithInterpreter && notStage0
```

to:

```text
(ghcWithInterpreter && notStage0) || stage1
```

That also did not affect the final compiler: nixpkgs invokes a prebuilt
`hadrian` executable from `nativeBuildInputs`, so patching the Hadrian source
copy inside the GHC source tree does not change the already-compiled Hadrian
package rules.

The third attempt used a supported Hadrian user setting to pass a GHC Haskell
compile option directly to the stage1 Cabal package `ghc`:

```text
stage1.ghc.ghc.hs.opts += -DHAVE_INTERNAL_INTERPRETER
```

That setting also reached `hadrianFlags`, but the rebuilt compiler still failed
with the same panic:

```text
stage1.ghc.ghc.hs.opts += -DHAVE_INTERNAL_INTERPRETER
loadExternalPlugins: can't load external plugins with GHC built without internal interpreter
```

The likely reason is stage naming in cross mode: the installed stage1 cross
compiler is built in Hadrian's stage0 context. An intermediate diagnostic patch
then bypassed the exact source guard in `compiler/GHC/Driver/Plugins.hs`:

```text
#if !defined(HAVE_INTERNAL_INTERPRETER)
```

is patched to:

```text
#if 0
```

The first direct-guard patch proved the source patch was applied, but it opened
implementation code whose imports and language extensions are guarded
separately by:

```text
#if defined(HAVE_INTERNAL_INTERPRETER) && defined(CAN_LOAD_DLL)
```

Without that guard, compilation failed on `LambdaCase` and unboxed tuple syntax.
The diagnostic patch therefore also changed those guards to:

```text
#if defined(CAN_LOAD_DLL)
```

That was useful, but it is not the minimized patch. The current minimized
experiment no longer patches `GHC.Driver.Plugins`. Instead, it forces the
intended `HAVE_INTERNAL_INTERPRETER` build macro by patching the Cabal
configuration:

```text
compiler/ghc.cabal.in
```

from:

```text
if flag(internal-interpreter)
    CPP-Options: -DHAVE_INTERNAL_INTERPRETER
```

to:

```text
CPP-Options: -DHAVE_INTERNAL_INTERPRETER
```

`CAN_LOAD_DLL` is not patched. It remains controlled by the
`dynamic-system-linker` Cabal flag:

```text
if flag(dynamic-system-linker)
    CPP-Options: -DCAN_LOAD_DLL
```

Observed result from the diagnostic patch, which the cabal-level patch is meant
to preserve in a cleaner way: the rebuilt GHC gets past the preprocessor gates
and reaches the real shared-library loader. The next failure was:

```text
loadExternalPluginLib
Can't load plugin library
  Library path: /nix/store/.../libHSth-cross-plugin-...-ghc9.10.3.so
  Error       : /nix/store/...-ghc-9.10.3/.../libHSghc-prim-0.12.0-...-ghc9.10.3.so:
                undefined symbol: stg_gc_unpt_r1
```

This is progress. It confirms that `-fplugin-library` can reach
`GHCi.ObjLink.loadDLL` when the GHC source guard is bypassed and `CAN_LOAD_DLL`
is available. It also shows a new blocker: the plugin shared library was built
like a normal native GHC plugin and depends on native GHC package libraries/RTS
symbols that the statically linked cross-GHC process does not export in the
shape expected by the loader.

ELF inspection showed:

```text
plugin .so:
  undefined stg_gc_unpt_r1

cross-GHC executable:
  stg_gc_unpt_r1 exists in the normal symbol table
  stg_gc_unpt_r1 is absent from the dynamic symbol table

native RTS .so:
  exports stg_gc_unpt_r1
```

The first export-dynamic attempt linked `stage1.ghc-bin` with exported dynamic
symbols while keeping the diagnostic `GHC.Driver.Plugins` source patch:

```text
stage1.ghc-bin.ghc.link.opts += -optl-Wl,--export-dynamic
```

That did not change the resulting executable's dynamic symbol table. The reason
is visible in Hadrian:

```text
hadrian/src/Rules/Program.hs
```

For cross builds, `buildProgram` copies `stage0/bin/<program>` to
`stage1/bin/<program>` instead of linking the stage1 program directly. Therefore
the relevant executable link option must be applied to `stage0.ghc-bin`:

```text
stage0.ghc-bin.ghc.link.opts += -optl-Wl,--export-dynamic
```

This mirrors the existing Hadrian rule for `iserv`, which adds the same linker
option so dynamically loaded objects can refer to RTS symbols.

Observed result after applying the linker option to `stage0.ghc-bin`:

```text
compile NoTH.hs with -fplugin-library:

compileExit=0
status=ok
```

This confirms that the patched cross-GHC can load the plugin shared library via
`-fplugin-library`. The flake also exposes the next smoke test, which compiles
`Example.hs` through `THCross.Plugin` and the GHC 9.8.4 host worker:

```bash
nix build .#consumer-ghc9103-cross-worker-smoke -L
cat result
```

The first worker-smoke run reached the hook and the host worker but failed
afterwards:

```text
th-cross: intercepted Template Haskell splice
th-cross: started worker /nix/store/.../bin/th-host-worker
th-host-worker: cache miss /nix/store/...-Example.hs
<no location info>: error:
    Template haskell requires a target code interpreter

compileExit=1
status=blocked
```

The error is not from `tcTopSpliceExpr`; that function only typechecks the
splice expression and does not call `tcGetInterp`. The relevant path is the
empty module-finalizer path for an already expanded untyped splice:

```text
GHC.Rename.Splice.rnUntypedSpliceExpr
GHC.Tc.Gen.Splice.getUntypedSpliceBody
GHC.Tc.Utils.Monad.addModFinalizersWithLclEnv
GHC.Tc.Module.run_th_modfinalizers
GHC.Tc.Gen.Splice.runRemoteModFinalizers
GHC.Tc.Gen.Splice.tcGetInterp
```

`addModFinalizersWithLclEnv` stores `ThModFinalizers []` unconditionally. Later,
`runRemoteModFinalizers (ThModFinalizers [])` calls `tcGetInterp` before it
checks whether there is any work to do. For this prototype, the forced cross-GHC
experiment now also patches the empty case:

```haskell
addModFinalizersWithLclEnv (ThModFinalizers []) = pure ()
addModFinalizersWithLclEnv mod_finalizers = ...
```

Observed result after replacing the direct `GHC.Driver.Plugins` guard patch with
the cabal-level `HAVE_INTERNAL_INTERPRETER` patch and adding the empty-finalizer
patch:

```text
compile Example.hs with -fplugin-library and host worker:
th-cross: intercepted Template Haskell splice
module: Example
kind: expression
worker: /nix/store/.../bin/th-host-worker
th-cross: started worker /nix/store/.../bin/th-host-worker
th-host-worker: cache miss /nix/store/...-Example.hs

compileExit=0
status=ok
```

The final working patch set and its upstream status are documented in
`docs/ghc-cross-patches.md`.

### Internal Static Plugin Or Patched GHC Main

If a suitable `-fplugin-library` cross-GHC cannot be obtained for another GHC
version or target, one fallback is to avoid runtime plugin loading entirely.
Link `THCross.Plugin.plugin` into the compiler/driver side and install it as an
internal static plugin, or patch the GHC frontend to install the same
`runMetaHook` directly.

Expected shape:

```text
cross GHC executable already contains THCross plugin logic
  -> no GHC.Runtime.Loader dynamic plugin load
  -> no plugin-loading call to hscInterp
  -> runMetaHook can call the native host worker
```

This is a narrower proof-of-concept path than redesigning GHC's dynamic plugin
loader. It tests the real mechanism we care about: whether cross-side TH splice
evaluation can be intercepted and replaced before the target interpreter is
needed for TH itself.

The source-level questions for this path are:

```text
where staticPlugins are stored in HscEnv / DynFlags;
where GHC's normal frontend initializes static plugins;
whether a small custom GHC main can inject THCross.Plugin.plugin;
whether a minimal GHC source patch is simpler than a custom driver.
```

### Loader Patch

Patching only `checkExternalInterpreter` is not enough. Even if that guard is
removed, `getValueSafely` still needs a way to load the plugin value without
`hscInterp`. A loader patch would have to distinguish host-loadable compiler
plugins from target-interpreted code and provide a build-host loading path for
the plugin module.

That is a larger and more invasive GHC change. It may be the right long-term
UX if we need to keep the normal command line:

```bash
-fplugin=THCross.Plugin
```

but it is not the smallest next proof-of-concept step.

### Stub Interpreter

A target interpreter stub is unlikely to solve the dynamic plugin problem by
itself. The plugin loader explicitly rejects `ExternalInterp`, while the
non-external path still requires `hscInterp` to obtain the plugin value. A stub
may become relevant later for other GHC checks, but it does not address the
observed `-fplugin` loading conflict directly.
