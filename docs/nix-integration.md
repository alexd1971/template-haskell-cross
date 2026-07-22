# Nix Integration

This document records the first Nix integration step for the TH cross prototype.

## Goal

Task 20's final target is a haskell.nix/cross build where:

```text
buildPackages:
  native th-host-worker
  native host GHC
  host TH dependencies

cross package set:
  cross GHC
  target dependencies
  THCross plugin
```

The first implementation step is intentionally smaller: prove the local Nix
shape before adding Android or haskell.nix cross details. The current flake has
two roles:

- `hostHaskellPkgs`: native host-side Haskell package set, currently GHC 9.8.4;
- `consumerGhc9103HaskellPkgs`: the Haskell package set that consumes
  `THCross.Plugin`, currently native GHC 9.10.3.
- `consumerGhc948HaskellPkgs`: native GHC 9.4.8 compatibility package set for
  the consumer-side plugin.

The consumer package sets are deliberately named by role and GHC version rather
than by target. They mark the places where a future cross target package set
should be introduced.

The current flake exposes only `x86_64-linux` outputs. Adding `aarch64-linux`
to the flake `systems` list would mean "evaluate this flake on an ARM Linux
host"; it would not enable Android cross-compilation. The Android target should
be introduced later as a separate target package set.

## Current Flake

`flake.nix` exposes:

```text
packages.${system}.host-ghc984-worker
packages.${system}.host-ghc984-plugin
packages.${system}.consumer-ghc948-plugin
packages.${system}.consumer-ghc948-ghc
packages.${system}.consumer-ghc948-cross-plugin-no-th-smoke
packages.${system}.consumer-ghc948-cross-worker-smoke
packages.${system}.consumer-ghc9103-cross-ghc-bootstrapped
packages.${system}.consumer-ghc9103-cross-ghc-forced-internal-interpreter
packages.${system}.consumer-ghc9103-cross-plugin-library-bootstrapped-probe
packages.${system}.consumer-ghc9103-cross-plugin-library-forced-internal-interpreter-probe
packages.${system}.consumer-ghc9103-cross-worker-smoke
packages.${system}.consumer-ghc9103-cross-cabal-package
packages.${system}.consumer-ghc9103-cross-generic-package
packages.${system}.consumer-ghc9103-cross-microlens-package
packages.${system}.consumer-ghc9103-cross-microlens-cabal-context-probe
packages.${system}.consumer-ghc9103-cross-executable-package
packages.${system}.consumer-ghc9103-cross-executable-qemu-smoke
packages.${system}.consumer-ghc9103-cross-plugin-library-probe
packages.${system}.consumer-ghc9103-plugin
packages.${system}.consumer-ghc9103-ghc
packages.${system}.consumer-ghc9103-package
packages.${system}.aarch64-linux-cross-probe
checks.${system}.consumer-ghc9103-worker-smoke
checks.${system}.consumer-ghc9103-package
checks.${system}.consumer-ghc948-plugin
checks.${system}.consumer-ghc948-worker-smoke
checks.${system}.cross-target-probe-aarch64-linux
devShells.${system}.default
apps.${system}.regen-cabal-nix
```

The package split mirrors the intended cross architecture, but still runs on one
host architecture:

- `host-ghc984-worker` comes from `hostHaskellPkgs` and is built with GHC 9.8.4;
- `host-ghc984-plugin` is the GHC 9.8.4 plugin build used by the local
  prototype;
- `consumer-ghc948-plugin` is a native GHC 9.4.8 compatibility build for the
  consumer-side plugin;
- `consumer-ghc948-ghc` is a GHC 9.4.8 environment containing
  `th-cross-plugin`;
- `consumer-ghc948-cross-plugin-no-th-smoke` is an explicit aarch64 cross-GHC
  plugin-loading smoke test without Template Haskell splices;
- `consumer-ghc948-cross-worker-smoke` is an explicit aarch64 cross-GHC smoke
  test with a Template Haskell splice. These cross smoke packages are not part
  of `flake check`, because they may build the large cross-GHC closure;
- `consumer-ghc9103-cross-plugin-library-probe` checks whether the plain
  nixpkgs aarch64 cross-GHC 9.10.3 can load `THCross.Plugin` through
  `-fplugin-library`. It writes a report instead of failing the derivation,
  because the current result is an expected blocker;
- `consumer-ghc9103-cross-ghc-bootstrapped` is an experimental aarch64
  cross-GHC 9.10.3 built with native GHC 9.10.3 as its bootstrap compiler;
- `consumer-ghc9103-cross-plugin-library-bootstrapped-probe` runs the same
  `-fplugin-library` check against `consumer-ghc9103-cross-ghc-bootstrapped`.
  This tests whether satisfying Hadrian's same-version bootstrap condition is
  enough to enable the internal interpreter path needed by external static
  plugins;
- `consumer-ghc9103-cross-ghc-forced-internal-interpreter` is a second
  experimental aarch64 cross-GHC 9.10.3. It keeps the same-version bootstrap and
  forces `HAVE_INTERNAL_INTERPRETER` for the compiler package at Cabal
  configuration level;
- `consumer-ghc9103-cross-plugin-library-forced-internal-interpreter-probe`
  runs the `-fplugin-library` check against that forced build;
- `consumer-ghc9103-cross-worker-smoke` uses that forced cross-GHC to compile a
  real expression splice through `THCross.Plugin` and the GHC 9.8.4 host worker;
- `consumer-ghc9103-cross-cabal-package` copies the checked-in
  `th-consumer-example` package, runs Cabal's `Setup configure`, `Setup build`,
  and `Setup copy` with the forced aarch64 cross-GHC, and installs the package
  output under `$out`;
- `consumer-ghc9103-cross-generic-package` builds the same checked-in
  `th-consumer-example` package through nixpkgs' Haskell generic builder. It
  constructs a target Haskell package set around the patched aarch64 cross-GHC,
  uses native GHC 9.10.3 for `Setup.hs`, reads native plugin metadata with
  `ghc-pkg`, passes `-fplugin-library` in `preConfigure`, and lets the generic
  builder provide cross `ghc`, `ghc-pkg`, `gcc`, `ld`, `ar`, `strip`, package
  DB, and install layout handling. This is the current preferred package-level
  Nix shape;
- `consumer-ghc9103-cross-microlens-package` builds
  `th-microlens-consumer`, a small package that depends on the real
  `microlens-th` generator package and runs a declaration splice
  `makeLenses ''User` through the GHC 9.8.4 host worker while cross-compiling
  the package with the patched aarch64 GHC 9.10.3;
- `consumer-ghc9103-cross-executable-package` builds
  `th-executable-consumer`, an executable-only package with the same
  `microlens-th` declaration splice. This checks that host package discovery is
  not limited to library components;
- `consumer-ghc9103-cross-executable-qemu-smoke` runs the aarch64 executable
  from `consumer-ghc9103-cross-executable-package` under `qemu-aarch64` and
  checks that it prints `"Ada"`;
- `consumer-ghc9103-plugin` comes from `consumerGhc9103HaskellPkgs` and is
  built with GHC 9.10.3;
- `consumer-ghc9103-ghc` is a `consumerGhc9103HaskellPkgs` GHC environment
  containing `th-cross-plugin`;
- `checks.${system}.consumer-ghc9103-worker-smoke` compiles `Example.hs` with
  `consumer-ghc9103-ghc` and passes the Nix-built GHC 9.8.4 worker path to the
  plugin.
- `consumer-ghc9103-package` is a minimal Cabal package from
  `consumerGhc9103HaskellPkgs` compiled natively with the standard GHC TH
  evaluator. Package-level plugin/worker wiring is covered by the cross package
  derivations below, where it is actually needed.
- `aarch64-linux-cross-probe` records the plain nixpkgs
  `pkgsCross.aarch64-multiplatform` split without pretending that a real GHC
  9.8.4 target package set is available there.

The Nix worker derivation wraps `th-host-worker` with:

```text
TH_HOST_GHC_LIBDIR=/nix/store/...-ghc-9.8.4/lib/ghc-9.8.4/lib
```

This prevents the worker from discovering the consumer GHC 9.10.3 via `PATH`
while evaluating host-side TH.
The libdir is passed explicitly from `nix/flake/haskell-pkgs.nix`; it is not
inferred from a generic `ghc` argument in the worker wrapper, because that can
accidentally resolve to the consumer compiler package set.

Experiments that evaluate TH generators from dependencies wrap the worker with
an additional host-side package environment. In the current generic-builder
prototype, the wrapper first instantiates the package normally with nixpkgs'
Haskell builder and reads its `passthru.getCabalDeps`. That exposes concrete
dependency derivations grouped by component-specific `*HaskellDepends` fields.
The integration extracts each dependency's Haskell `pname`, filters out boot
packages such as `base` and `template-haskell`, and builds a GHC 9.8.4
`ghcWithPackages` environment for those names. For example,
`consumer-ghc9103-cross-microlens-package` derives `microlens` and
`microlens-th`, then passes the matching libdir to the worker wrapper:

```text
TH_HOST_GHC_LIBDIR=/nix/store/...-ghc-9.8.4-with-packages/lib/ghc-9.8.4/lib
```

The same derived names are resolved through the host GHC package DB with
`ghc-pkg field <package> id --simple-output`, then passed as exact host package
exposure through plugin options:

```text
-fplugin-opt=THCross.Plugin:host-package-id=microlens-0.4.14.0-...
-fplugin-opt=THCross.Plugin:host-package-id=microlens-th-0.4.3.17-...
```

The plugin serializes these unit ids into the JSON-lines splice request as
`hostPackageIds`. The worker turns them into host-side `-package-id` flags
before loading the source module. `TH_HOST_GHC_PACKAGE_IDS` is accepted as an
environment-variable fallback for manual experiments, but the preferred
prototype path is exact unit-id data from the cross-side plugin.

This uses nixpkgs' own evaluation-time Haskell dependency metadata instead of
parsing the `.cabal` file directly. It still assumes that each extracted package
`pname` is available under the same attribute name in
`pkgs.haskell.packages.ghc984`. Resolving the final GHC unit id through host
`ghc-pkg` avoids ambiguity between multiple installed instances, but the
surrounding package selection is not yet a complete Cabal component context
model.

Worker-enabled package builds validate this evaluation-time dependency context
after `Setup configure`. The validation reads Cabal's persisted
`dist/setup-config`, extracts Cabal-resolved package names for all configured
components, filters out boot packages, and compares the result with the
evaluation-time names used to build the host worker package DB. The build fails
before `Setup build` if the sets differ.

### Cabal `setup-config` Probe

The experiment also exposes the same validation as a standalone probe for
inspection:

```bash
nix build .#consumer-ghc9103-cross-microlens-cabal-context-probe -L --allow-import-from-derivation
cat result/nix-support/cabal-component-deps
```

The probe runs after `Setup configure`, reads Cabal's persisted
`dist/setup-config` with `Distribution.Simple.Configure.getPersistBuildConfig`,
walks `Distribution.Simple.LocalBuildInfo.allComponentsInBuildOrder`, and
prints each component's `componentPackageDeps`.

The output includes:

```text
result/nix-support/cabal-component-deps
result/nix-support/cabal-derived-package-names
result/nix-support/nix-derived-host-package-names.sorted
result/nix-support/package-name-diff
```

For the current `microlens` fixture, the Cabal-derived and Nix-derived package
name sets both contain:

```text
microlens
microlens-th
```

Worker-enabled builds and the standalone probe both fail if those sets diverge.

The Cabal `setup-config` data is the most direct source for Cabal-resolved
component dependencies, but it is produced during the build phase. That is too
late to choose the Nix host `ghcWithPackages` closure for the same derivation,
because Nix store inputs must already be fixed during evaluation. The current
integration therefore uses nixpkgs dependency metadata to choose the host
package closure and uses `setup-config` as a fail-fast validation source.

The top-level `flake.nix` is intentionally only a thin entrypoint. The Nix
flake implementation lives under `nix/flake/`:

```text
nix/flake/default.nix
nix/flake/haskell-pkgs.nix
nix/flake/lib.nix
nix/flake/cross-ghc/ghc9103-aarch64.nix
nix/flake/experiments/*.nix
```

Cross-GHC construction is kept under `nix/flake/cross-ghc/`; experiment modules
consume those compiler derivations instead of defining toolchains inline.

The Haskell package derivations are checked in under `nix/generated/` instead
of using `callCabal2nix` during flake evaluation. This avoids requiring
`allow-import-from-derivation`.

Files under `nix/generated/` are generated from Cabal files and may be
overwritten by `nix run .#regen-cabal-nix`. Files directly under `nix/` are
manual wrappers that apply project-specific overrides, such as disabling tests
and wrapping the worker with `TH_HOST_GHC_LIBDIR`.

`th-cross-plugin` package test suites are disabled in the package derivation.
The existing Cabal integration test expects the repository-level
`prototype/cabal.project`, which is not present in the isolated source tree used
by the package derivation. Nix-level validation is handled by
`checks.${system}.consumer-ghc9103-worker-smoke` instead.

## Commands

Build the native worker:

```bash
nix build .#host-ghc984-worker
```

Build the consumer-side plugin with GHC 9.10.3:

```bash
nix build .#consumer-ghc9103-plugin
```

Build the consumer-side plugin with GHC 9.4.8:

```bash
nix build .#consumer-ghc948-plugin
```

Build the GHC 9.4.8 consumer environment:

```bash
nix build .#consumer-ghc948-ghc
```

The same build is also part of:

```bash
nix flake check
```

Run the GHC 9.4.8 consumer plugin smoke test against the GHC 9.8.4 worker:

```bash
nix build .#checks.x86_64-linux.consumer-ghc948-worker-smoke -L
```

Run the explicit aarch64 cross-GHC 9.4.8 smoke test against the native GHC
9.4.8 plugin and GHC 9.8.4 worker:

```bash
nix build .#consumer-ghc948-cross-worker-smoke -L
```

Run the same cross-GHC/plugin wiring without Template Haskell splices:

```bash
nix build .#consumer-ghc948-cross-plugin-no-th-smoke -L
```

These are intentionally packages, not default flake checks. Building them may
pull in the full plain-nixpkgs aarch64 cross-GHC 9.4.8 closure.

Current result: the correct build-host executable cross-GHC is
`pkgsCross.aarch64-multiplatform.buildPackages.haskell.compiler.ghc948`.
Its wrapper reports:

```text
("cross compiling","YES")
```

and the internal compiler binary is `x86-64`. This is the correct shape for
loading a native GHC plugin.

The current blocker is GHC 9.4's cross-GHC plugin loading path. A control
compile of `NoTH.hs` without `-fplugin` succeeds with `-fno-external-interpreter`.
The same `NoTH.hs` compile with `THCross.Plugin` enabled fails before any
Template Haskell splice is involved:

```text
Couldn't find a target code interpreter. Try with -fexternal-interpreter
```

Using `-fexternal-interpreter` is not accepted with plugins:

```text
Plugins require -fno-external-interpreter
```

So the blocker is earlier than `runMetaHook`: this GHC 9.4 cross setup requires
a target code interpreter just to load/use a GHC plugin.

The source-level analysis and possible workaround paths are recorded in
`docs/plain-nixpkgs-cross-ghc.md`.

Run the explicit aarch64 cross-GHC 9.10.3 `-fplugin-library` probe:

```bash
nix build .#consumer-ghc9103-cross-plugin-library-probe -L
cat result
```

Current result: plain nixpkgs provides an aarch64-producing GHC 9.10.3
build-host executable, and that executable exposes `-fplugin-library`. The
probe still cannot load the external static plugin because this GHC package was
built without the internal interpreter code path needed by
`GHC.Driver.Plugins.loadExternalPlugins`:

```text
loadExternalPlugins: can't load external plugins with GHC built without internal interpreter
```

Build the experimental aarch64 cross-GHC 9.10.3 with same-version bootstrap:

```bash
nix build .#consumer-ghc9103-cross-ghc-bootstrapped -L
```

This output is intentionally separate from the plain nixpkgs cross-GHC. It
overrides the cross-GHC bootstrap package set to native GHC 9.10.3, so GHC
reports:

```text
("Booter version","9.10.3")
("Stage","1")
("cross compiling","YES")
```

Run the `-fplugin-library` probe against that bootstrapped cross-GHC:

```bash
nix build .#consumer-ghc9103-cross-plugin-library-bootstrapped-probe -L
cat result
```

Current result: this confirms the same-version bootstrap shape but still fails
in `GHC.Driver.Plugins.loadExternalPlugins`:

```text
("Booter version","9.10.3")
("Stage","1")
loadExternalPlugins: can't load external plugins with GHC built without internal interpreter
```

So the same-version bootstrap condition alone is not sufficient for the tested
nixpkgs GHC 9.10.3 cross derivation. The next experiment needs to force the
relevant `internal-interpreter` Cabal flag/CPP path or patch
`loadExternalPlugins` directly.

Run the forced `internal-interpreter` experiment:

```bash
nix build .#consumer-ghc9103-cross-plugin-library-forced-internal-interpreter-probe -L
cat result
```

This is expected to be a heavy build. It deliberately does not replace the
plain or bootstrapped probes, because those remain useful as negative controls.
The first attempt used `hadrianFlags` with `cabal.configure.opts +=
--flags=internal-interpreter`. The build log confirmed those command-line
settings reached Hadrian, but the resulting compiler still failed with the same
panic. The likely reason is that Hadrian computes package flags separately via
the `Cabal Flags` builder and then appends its own final `--flags=...` argument.

The second attempt patched `hadrian/src/Settings/Packages.hs` inside the GHC
source tree, changing the existing `internal-interpreter` Cabal flag condition
from:

```text
ghcWithInterpreter && notStage0
```

to:

```text
(ghcWithInterpreter && notStage0) || stage1
```

That did not affect the build: nixpkgs invokes a prebuilt `hadrian` executable
from `nativeBuildInputs`, so patching the source copy of Hadrian in the GHC
source tree does not change Hadrian's already-compiled package rules.

The third attempt used a supported Hadrian user setting for GHC Haskell compile
options:

```text
stage1.ghc.ghc.hs.opts += -DHAVE_INTERNAL_INTERPRETER
```

That setting also reached `hadrianFlags`, but the rebuilt compiler still took
the same panic branch. The likely reason is again stage naming: the installed
stage1 cross compiler is built in Hadrian's stage0 context, so the setting did
not affect the package instance that produced the running compiler.

An intermediate diagnostic patch bypassed the actual source guard in
`compiler/GHC/Driver/Plugins.hs` and confirmed that the loader path works once
the guard is passed. The current minimized experiment no longer patches
`GHC.Driver.Plugins`. Instead, it forces the intended build macro at the Cabal
configuration level by patching:

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

`CAN_LOAD_DLL` is not patched. It is already controlled by the `dynamic-system-linker`
Cabal flag in `compiler/ghc.cabal.in`, and the tested Linux build has it
enabled:

```text
if flag(dynamic-system-linker)
    CPP-Options: -DCAN_LOAD_DLL
```

With the cabal-level `HAVE_INTERNAL_INTERPRETER` patch, the important question
is still whether the rebuilt compiler no longer fails with:

```text
loadExternalPlugins: can't load external plugins with GHC built without internal interpreter
```

Observed result: the diagnostic patch passes both preprocessor gates and reaches
the real shared-library loader. The next blocker is now `loadDLL`:

```text
loadExternalPluginLib
Can't load plugin library
  Library path: /nix/store/.../libHSth-cross-plugin-...-ghc9.10.3.so
  Error       : /nix/store/...-ghc-9.10.3/.../libHSghc-prim-0.12.0-...-ghc9.10.3.so:
                undefined symbol: stg_gc_unpt_r1
```

This confirms that `-fplugin-library` can reach the object linker after the GHC
source guard is bypassed. It also shows that loading a normal GHC plugin shared
library into this statically linked cross-GHC is not enough: the plugin's native
GHC package libraries expect RTS symbols that are not available to the loader in
the current process shape.

The executable contains `stg_gc_unpt_r1` in its normal symbol table, but not in
its dynamic symbol table. The native RTS shared library also exports that
symbol.

The first export-dynamic attempt used:

```text
stage1.ghc-bin.ghc.link.opts += -optl-Wl,--export-dynamic
```

That did not change the resulting executable's dynamic symbol table. The reason
is Hadrian's cross-program rule in:

```text
hadrian/src/Rules/Program.hs
```

For cross builds, `buildProgram` copies `stage0/bin/<program>` to
`stage1/bin/<program>` instead of linking the stage1 program directly. Therefore
the next experiment keeps the diagnostic `GHC.Driver.Plugins` patch but exports
dynamic symbols from the stage0 `ghc-bin` executable:

```text
stage0.ghc-bin.ghc.link.opts += -optl-Wl,--export-dynamic
```

This still mirrors the existing Hadrian rule for `iserv`, whose comment says
`--export-dynamic` is needed so dynamically loaded objects can refer to RTS
symbols.

Observed result after applying the linker option to `stage0.ghc-bin`:

```text
compile NoTH.hs with -fplugin-library:

compileExit=0
status=ok
```

This confirms only dynamic plugin loading. It does not yet prove that the
cross-GHC can compile a TH module through the worker. The next smoke test uses
the same forced cross-GHC but compiles `Example.hs`:

```bash
nix build .#consumer-ghc9103-cross-worker-smoke -L
cat result
```

First worker-smoke result:

```text
th-cross: intercepted Template Haskell splice
th-cross: started worker /nix/store/.../bin/th-host-worker
th-host-worker: cache miss /nix/store/...-Example.hs
<no location info>: error:
    Template haskell requires a target code interpreter

compileExit=1
status=blocked
```

This is after the plugin hook and worker path have run. The source-level reason
is another cross-GHC finalizer edge:

```text
GHC.Rename.Splice.rnUntypedSpliceExpr
  -> stores HsUntypedSpliceTop (ThModFinalizers mod_finalizers) expandedExpr

GHC.Tc.Gen.Splice.getUntypedSpliceBody
  -> addModFinalizersWithLclEnv mod_finalizers

GHC.Tc.Utils.Monad.addModFinalizersWithLclEnv
  -> stores the finalizer list unconditionally

GHC.Tc.Module.run_th_modfinalizers
  -> runRemoteModFinalizers

GHC.Tc.Gen.Splice.runRemoteModFinalizers
  -> tcGetInterp, even for ThModFinalizers []
```

For the simple `Example.hs` splice there are no module finalizers. The forced
cross-GHC experiment now applies a second diagnostic patch:

```haskell
addModFinalizersWithLclEnv (ThModFinalizers []) = pure ()
addModFinalizersWithLclEnv mod_finalizers = ...
```

This preserves non-empty finalizers but avoids requiring a target interpreter
for an empty finalizer list produced by an already-expanded untyped splice.

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

This is the current minimal successful cross smoke for the Nix experiment. It
does not patch `GHC.Driver.Plugins` directly.

The GHC source edits are kept as reviewable patch files:

```text
nix/patches/ghc-9.10.3-force-compiler-internal-interpreter.patch
nix/patches/ghc-9.10.3-ignore-empty-th-finalizers.patch
```

Build the consumer GHC environment:

```bash
nix build .#consumer-ghc9103-ghc
```

Build the package-level consumer example:

```bash
nix build .#consumer-ghc9103-package
```

Run the aarch64 cross-GHC Cabal package smoke:

```bash
nix build .#consumer-ghc9103-cross-cabal-package
cat result/nix-support/build-log
```

Run the same package through nixpkgs' Haskell generic builder:

```bash
nix build .#consumer-ghc9103-cross-generic-package -L --allow-import-from-derivation
find -L result -maxdepth 7 \( -type f -o -type l \) | sort
```

Observed result: the generic builder invokes the patched
`aarch64-unknown-linux-gnu-ghc-9.10.3`, loads `THCross.Plugin` through
`-fplugin-library`, starts the GHC 9.8.4 host worker, expands the expression
splice from `src/Example.hs`, where the splice calls a generator imported from
`src/Gen.hs`, and installs target package artifacts including the package conf,
`.hi`, `.dyn_hi`, static library, and shared library.

Run the small real-generator dependency smoke:

```bash
nix build .#consumer-ghc9103-cross-microlens-package -L --allow-import-from-derivation
find -L result -maxdepth 8 \( -name 'Example*.hi' -o -name 'Example*.dyn_hi' -o -name '*.conf' \) -print
```

Observed result: the package installs aarch64 target artifacts for
`th-microlens-consumer`, including `Example.hi`, `Example.dyn_hi`, and a package
conf. During the build, the cross-GHC intercepts the declaration splice:

```text
module: Example
kind: declaration
expression: makeLenses ''User
worker: /nix/store/...-th-host-worker-ghc984-with-host-packages/bin/th-host-worker
th-host-worker: cache miss src/Example.hs
```

This confirms a stronger case than the local toy package:

- the splice generator comes from a real dependency package, `microlens-th`;
- the worker loads the source module with a host-side package DB containing
  `microlens` and `microlens-th`;
- the host worker evaluates a declaration splice that uses `reify`;
- the generated declarations are returned as text, parsed by the cross-GHC, and
  renamed/typechecked in the target module;
- the target package is built and installed as an aarch64 package.

Run the executable-component dependency smoke:

```bash
nix build .#consumer-ghc9103-cross-executable-package -L --allow-import-from-derivation
find -L result -maxdepth 8 \( -name 'th-executable-consumer' -o -name '*.conf' \) -print
```

Observed result: the package builds an aarch64 executable component and the same
automatic host-package mechanism derives package names from
`executableHaskellDepends`, not `libraryHaskellDepends`.

Run the resulting aarch64 executable under qemu:

```bash
nix build .#consumer-ghc9103-cross-executable-qemu-smoke -L --allow-import-from-derivation
cat result
```

Expected report:

```text
output="Ada"
status=ok
```

Current blocker: host-side dependency context derivation is improved but still
incomplete. The Nix experiment reads nixpkgs Haskell derivation
`passthru.getCabalDeps`, extracts dependency `pname`s, builds a matching GHC
9.8.4 host package DB, resolves exact host unit ids with host `ghc-pkg`, and
passes matching `host-package-id` plugin options automatically. It also validates
the selected package names against Cabal `setup-config` after configuration. A
production integration still needs a model for renamed packages, internal
libraries, setup dependencies, and packages whose host package-set attribute is
not the same as the Cabal package name.

Inspect the plain nixpkgs aarch64-linux cross probe:

```bash
nix build .#aarch64-linux-cross-probe
cat result
```

Run the local cross-version check:

```bash
nix flake check
```

Regenerate checked-in Cabal-derived Nix files after `.cabal` changes:

```bash
nix run .#regen-cabal-nix
```

This app is intended for repository maintenance. It writes generated files under
`nix/generated/`; it is not part of pure flake evaluation.

Observed check output:

```text
th-cross-consumer-ghc9103-worker-smoke> th-cross: intercepted Template Haskell splice
th-cross-consumer-ghc9103-worker-smoke> module: Example
th-cross-consumer-ghc9103-worker-smoke> kind: expression
th-cross-consumer-ghc9103-worker-smoke> splice-key: db5b38a182e7327256576d7231cf0980
th-cross-consumer-ghc9103-worker-smoke> location: /nix/store/...-Example.hs:6:8-17
th-cross-consumer-ghc9103-worker-smoke> expression: ([| 42 |])
th-cross-consumer-ghc9103-worker-smoke> worker: /nix/store/...-th-host-worker-0.1.0.0/bin/th-host-worker
th-cross-consumer-ghc9103-worker-smoke> th-cross: started worker /nix/store/...-th-host-worker-0.1.0.0/bin/th-host-worker
th-cross-consumer-ghc9103-worker-smoke> th-host-worker: cache miss /nix/store/...-Example.hs
```

This confirms the local Nix wiring:

```text
GHC 9.10.3 plugin package
  -> /nix/store host worker built with GHC 9.8.4
  -> textual expression expansion
```

The worker smoke checks confirm direct `ghc` invocation wiring. The
package-level plugin path is covered by the cross Cabal/generic package builds
below.

The cross Cabal package derivation is the first package-shaped aarch64 build
path in this flake. It copies `prototype/th-consumer-example`, creates a
standard `Setup.hs`, runs `Setup configure` with the patched aarch64 cross-GHC,
then runs `Setup build` and `Setup copy`. The package output is installed under
`$out`; the diagnostic log is written to `$out/nix-support/build-log`.

Observed native package output:

```text
th-consumer-example> Building library for th-consumer-example-0.1.0.0...
th-consumer-example> [1 of 2] Compiling Gen
th-consumer-example> [2 of 2] Compiling Example
```

This native package build intentionally uses the standard GHC TH evaluator. The
cross package derivations disable library profiling so the check does not
compile a separate profiling object variant and does not execute the same
splice a second time only for `*.p_o` output.

Observed cross Cabal package output:

```text
cabal package: th-consumer-example
configure/build/copy with Setup.hs and cross-GHC:
Configuring th-consumer-example-0.1.0.0...
Preprocessing library for th-consumer-example-0.1.0.0...
Building library for th-consumer-example-0.1.0.0...
th-cross: intercepted Template Haskell splice
module: Example
kind: expression
location: src/Example.hs:8:8-12
expression: (gen)
worker: /nix/store/...-th-host-worker-0.1.0.0/bin/th-host-worker
th-cross: started worker /nix/store/...-th-host-worker-0.1.0.0/bin/th-host-worker
th-host-worker: cache miss src/Example.hs
Installing library in /nix/store/...-th-consumer-example-aarch64-unknown-linux-gnu-0.1.0.0/lib

status=ok
```

This confirms:

- Cabal reads the `th-consumer-example.cabal` package description;
- Cabal configures the library component with the patched aarch64 cross-GHC;
- the cross-GHC loads `THCross.Plugin` through `-fplugin-library`;
- the plugin delegates TH execution to the native GHC 9.8.4 worker;
- the worker evaluates a splice whose generator is imported from the package's
  separate `Gen` module;
- Cabal installs the resulting target library output under the derivation
  output path;
- Cabal receives target object output, unlike the earlier failed `-fno-code`
  attempt where `ar` could not find `Example.o`.

Observed cross-probe output:

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

This check is intentionally not a Haskell cross build. It records the current
plain nixpkgs limitation: evaluating cross GHC 9.8.4 in
`pkgsCross.aarch64-multiplatform` fails with nixpkgs' own
`GHC >= 9.6 can't be cross-compiled` error. The useful parts for the prototype
are:

- `buildPackages` still provides a native GHC 9.8.4 side, which is the right
  place for the host worker;
- plain nixpkgs exposes an aarch64-producing GHC 9.4.8 package set;
- the plugin should come from the native GHC 9.4.8 package set, because
  `-fplugin` loads code into the cross-GHC process running on the build host.
- the executable compiler for this smoke test comes from
  `pkgsCross.aarch64-multiplatform.buildPackages.haskell.compiler.ghc948`, not
  from `pkgsCross.aarch64-multiplatform.haskell.compiler.ghc948`.

The explicit `consumer-ghc948-cross-worker-smoke` package tests that wiring by
running the aarch64 cross-GHC with the native GHC 9.4.8 plugin package DB and
the native GHC 9.8.4 worker.

See `docs/plain-nixpkgs-cross-ghc.md` for the plain nixpkgs cross-GHC
investigation.

Enter a shell with both GHC versions and cabal:

```bash
nix develop
```

The shell prints a short command summary on entry.

It also exports linker search paths for Nix-provided native libraries such as
`gmp` and `zlib`. This is needed for manual Cabal builds inside `nix develop`;
otherwise GHC can compile modules but fail during linking with errors such as
`cannot find -lgmp`.

Inside `nix develop`, the shell provides versioned wrappers:

```text
ghc-9.8.4
ghc-9.8.4-pkg
ghc-9.10.3
ghc-9.10.3-pkg
th-cross-build
th-cross-test
```

The helper scripts use a separate Cabal store/build directory:

```text
.cabal-store-nix
dist-newstyle-nix
```

This avoids mixing Nix GHC package ids with packages previously built by ghcup
GHCs.

Build everything:

```bash
th-cross-build
```

Build a specific Cabal target:

```bash
th-cross-build th-host-worker
```

Run the integration test:

```bash
th-cross-test
```

The build helper is equivalent to:

```bash
cabal \
  --store-dir "$PWD/.cabal-store-nix" \
  build \
  --project-dir prototype \
  --builddir dist-newstyle-nix \
  --with-compiler ghc-9.8.4 \
  --with-hc-pkg ghc-9.8.4-pkg \
  all
```

## Next Step

The current local proof includes a successful Setup-based Cabal package
derivation for `th-consumer-example` with the patched aarch64 GHC 9.10.3 cross
compiler. The next Nix integration step should move from this hand-written
Setup-based derivation toward normal package-set integration:

- a native host package set for `th-host-worker`;
- a target package set for the consumer package;
- a compiler-plugin package database built for the compiler process, not for
  target runtime code;
- plugin configuration that passes either `-fplugin-library` for a suitable
  cross-GHC or the equivalent plugin package database flags where supported:

```text
-fplugin=THCross.Plugin
-fplugin-opt=THCross.Plugin:worker=/nix/store/.../bin/th-host-worker
```

Concrete next candidates are:

- try integrating the same flags into nixpkgs' Haskell generic builder for the
  consumer package;
- decide whether the Setup-based package derivation should become a reusable
  helper for package-level cross tests;
- only then add Android/aarch64 package-set details.

The current flake intentionally does not add `aarch64-linux` to `systems`.
`systems` controls which host systems evaluate the flake outputs; it is not the
same thing as an Android or aarch64 target package set.
