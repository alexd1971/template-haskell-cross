# Target Context and CPP

Target: GHC 9.8.4.

This document investigates how the host worker should reproduce the source
context seen by the cross GHC when Template Haskell is evaluated on the build
host.

## Current Prototype Behavior

The cross-side plugin sends the worker:

- module name;
- source file path;
- splice kind;
- source span;
- pretty-printed splice expression;
- cross GHC version;
- component unit id;
- host package ids;
- host source directories;
- explicit host GHC options.

It does not send:

- the full cross-side `DynFlags`;
- automatically extracted CPP options in the plugin itself;
- automatically extracted package flags;
- package database configuration;
- full Cabal component context;
- target platform settings;
- automatically derived target-specific include paths;
- automatically derived target-specific `-D` defines.

The host worker creates an independent native GHC session:

```haskell
runGhc (Just ghcLibDir) $ do
  dflags <- getSessionDynFlags
  setSessionDynFlags (applyHostGhcOptions (workerDynFlags dflags))
  installCaptureHook ...
  target <- guessTarget sourceFile Nothing Nothing
  setTargets [target]
  load LoadAllTargets
```

Current `workerDynFlags` changes:

```haskell
gopt_set dflags Opt_ForceRecomp
packageFlags = hostPackageIds ++ packageFlags dflags
importPaths = hostSourceDirs ++ sourceDir : importPaths dflags
objectDir = Just hostWorkerBuildDir
hiDir = Just hostWorkerBuildDir
stubDir = Just hostWorkerBuildDir
```

The worker then applies explicit `hostGhcOptions` from the request with
`parseDynamicFlagsFull`. This is currently a manual escape hatch used for
target-like preprocessing flags:

```text
-fplugin-opt=THCross.Plugin:host-ghc-option=-Dandroid_HOST_OS
-fplugin-opt=THCross.Plugin:host-ghc-option=-I/path/to/include
-fplugin-opt=THCross.Plugin:host-ghc-option=-optP...
```

So the worker can reproduce selected cross compiler options, but only when the
build integration passes them explicitly. The current Nix generic-builder
prototype derives unconditional Cabal `cpp-options` and passes each one as
`host-ghc-option=...`; the plugin does not infer those options from cross
`DynFlags` by itself.

## Relevant GHC 9.8.4 Fields

Relevant source paths:

| Area | Source path | Relevant definitions |
| --- | --- | --- |
| Dynamic compiler state | `compiler/GHC/Driver/DynFlags.hs` | `DynFlags`, `targetPlatform`, `toolSettings`, `platformMisc` |
| Platform | `compiler/GHC/Platform.hs` | `Platform`, `platformArch`, `platformOS` |
| TH worker | `prototype/th-host-worker/app/Worker/Evaluate.hs` | `captureModuleSplices`, `workerDynFlags` |
| Cross TH conversion | `prototype/th-cross-plugin/src/THCross/Plugin.hs` | converts raw TH payloads with cross-side GHC |

`DynFlags` contains:

```haskell
targetPlatform :: Platform
toolSettings   :: ToolSettings
platformMisc   :: PlatformMisc
```

In a real cross GHC session, `targetPlatform` describes the target platform of
the cross compiler. In the current worker session, `targetPlatform` describes
the native host GHC.

The local development environment confirms native-native settings:

```text
Build platform:  x86_64-unknown-linux
Host platform:   x86_64-unknown-linux
Target platform: x86_64-unknown-linux
target os:       OSLinux
target arch:     ArchX86_64
```

This environment cannot reproduce Android/iOS target CPP behavior without an
actual cross GHC.

## CPP Risk

GHC/Cabal CPP commonly uses macros such as:

```text
linux_HOST_OS
mingw32_HOST_OS
android_HOST_OS
x86_64_HOST_ARCH
aarch64_HOST_ARCH
__GLASGOW_HASKELL__
MIN_VERSION_package(...)
VERSION_package
CURRENT_PACKAGE_KEY
```

The confusing part is the `HOST_*` naming. In GHC package CPP conventions,
these macros describe the platform of the compiler target for the package being
compiled. For a cross GHC compiling an Android target, source may see
`android_HOST_OS`. A native host worker running native GHC on Linux will instead
see Linux-oriented CPP macros.

Example:

```haskell
#ifdef android_HOST_OS
data Platform = AndroidPlatform
#else
data Platform = LinuxPlatform
#endif

foo = $(do
  info <- reify ''Platform
  ...
 )
```

Current behavior:

- cross GHC may preprocess and typecheck `Platform = AndroidPlatform`;
- host worker loads the same file with native GHC and will see the target-like
  branch only if the relevant CPP options are forwarded with `host-ghc-option`;
- without forwarded options, the worker may see `Platform = LinuxPlatform`;
- `reify ''Platform` in the worker observes the wrong declaration;
- generated Haskell can disagree with the target-side module.

This is a semantic correctness issue, not just a cache-key issue.

## Package Flags and Cabal Context

CPP is not the only source of divergence.

The worker also needs the same component/package context:

- package databases;
- exposed packages;
- package flags and Cabal conditionals;
- include dirs;
- `-D` and `-U` CPP options;
- `-optP`/`-pgmP` preprocessing options;
- source directories and generated source directories;
- `MIN_VERSION_*` macros generated by Cabal;
- home-unit identity and package key/current package macros.

The current worker knows a minimal component context:

- `componentUnitId`;
- explicit host package ids;
- explicit host source dirs;
- explicit host GHC options.

It does not derive this context itself from the Cabal build plan. The Nix
prototype currently supplies these values explicitly for the consumer fixtures.

That is enough for the small prototype fixtures, but not enough for real
cross-package builds unless the build integration provides the right context.

## Can Host GHC Execute on Host but Preprocess Like Target?

Conceptually, yes, but only partially.

A host worker can execute TH on the build host while using target-like source
configuration if it is given:

```text
target-like CPP defines
target-like include paths
target-like package flags
target-like Cabal component context
host-buildable TH dependencies
```

But it cannot blindly use the full target GHC environment:

- target libraries may not be loadable/executable by native GHC;
- target-only imports may fail in the native worker;
- FFI declarations may refer to target-only headers/symbols;
- C compiler/linker settings for generated foreign files belong to the target
  build, not the host worker;
- packages with different exposed modules under flags may produce different
  source structure.

Therefore the host worker needs a split context:

```text
execute TH code with native host GHC
preprocess and resolve the source as close as possible to the cross target context
compile/import only modules that are host-buildable
```

This split is the central hard problem after the local prototype.

## MVP Scope

For the current MVP, require:

```text
the module containing splices is host-buildable
the module does not depend on target-only imports before the splice
host-side CPP result is equivalent to cross-side CPP result for declarations
observed by TH
host and cross GHC use compatible package flags for TH-observed code
```

If these are not true, the prototype may generate incorrect code.

## Recommended Next Implementation Steps

1. Extend `SpliceRequest` with a target/context fingerprint:
   ```text
   target platform
   CPP options
   package configuration fingerprint
   Cabal component id
   source hash
   ```
2. Expand the current Nix-side extraction from unconditional Cabal
   `cpp-options` to more of the component context:
   ```text
   -fplugin-opt=THCross.Plugin:host-ghc-option=-Dandroid_HOST_OS
   -fplugin-opt=THCross.Plugin:host-ghc-option=-I...
   ```
3. Preserve conditional Cabal choices and generated source/include directories
   rather than reading only unconditional fields from the `.cabal` syntax.
4. Add a diagnostic mode that logs native worker `targetPlatform` and relevant
   CPP/package options for each module load.
5. Expand cross-GHC tests from the current smoke fixtures to CPP-sensitive and
   package-context-sensitive modules.

## Recommendation

Do not claim automatic target-context correctness yet.

The current implementation is correct only when the native worker receives
enough explicit package, source-dir, and GHC-option context for all declarations
that TH can observe.

Before Android/iOS integration, derive this context from the cross build plan
instead of hand-written plugin options. Without that, `reify` can observe the
wrong module shape.

For modules that native GHC cannot load at all because of target-only imports,
packages, or FFI assumptions, see `docs/target-only-modules.md`.
