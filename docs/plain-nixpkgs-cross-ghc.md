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

The next preferred path is therefore more specific: obtain or build a cross-GHC
version that both exposes `-fplugin-library` and includes the internal
interpreter support required by `loadExternalPlugins`.

### Internal Static Plugin Or Patched GHC Main

If a suitable `-fplugin-library` cross-GHC cannot be obtained, the next fallback
is to avoid runtime plugin loading entirely. Link `THCross.Plugin.plugin` into
the compiler/driver side and install it as an internal static plugin, or patch
the GHC frontend to install the same `runMetaHook` directly.

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
