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
shape before adding Android or haskell.nix cross details. The current active
flake path has two roles:

- `hostGhc9103HaskellPkgs`: native host-side worker package set, built with a
  patched GHC 9.10.3;
- `consumerGhc9103HaskellPkgs`: the Haskell package set that consumes
  `THCross.Plugin`, currently native GHC 9.10.3.

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
packages.${system}.host-ghc9103-worker
packages.${system}.cross-ghc9103-aarch64-linux
packages.${system}.consumer-ghc9103-cross-generic-package
packages.${system}.consumer-ghc9103-cross-microlens-package
packages.${system}.consumer-ghc9103-cross-microlens-cabal-context-probe
packages.${system}.consumer-ghc9103-cross-executable-package
packages.${system}.consumer-ghc9103-cross-executable-qemu-smoke
packages.${system}.consumer-ghc9103-plugin
packages.${system}.consumer-ghc9103-ghc
packages.${system}.consumer-ghc9103-package
packages.${system}.aarch64-linux-cross-probe
checks.${system}.consumer-ghc9103-worker-smoke
checks.${system}.consumer-ghc9103-package
checks.${system}.cross-target-probe-aarch64-linux
devShells.${system}.default
apps.${system}.regen-cabal-nix
```

The package split mirrors the intended cross architecture, but still runs on one
host architecture:

- `host-ghc9103-worker` is built with a native patched GHC 9.10.3 that exports
  `runTHExp`, `runTHPat`, `runTHType`, and `runTHDec` from
  `GHC.Tc.Gen.Splice`. This is the active host worker for the raw Template
  Haskell AST protocol;
- `cross-ghc9103-aarch64-linux` — рабочий кросс-GHC 9.10.3 для
  `aarch64-linux` с тремя патчами (см. `docs/ghc-cross-patches.md`),
  поддерживающий загрузку плагина через `-fplugin-library`;
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
  `makeLenses ''User` through the host worker while cross-compiling
  the package with the patched aarch64 GHC 9.10.3;
- `consumer-ghc9103-cross-executable-package` builds
  `th-executable-consumer`, a package with a library component and an
  executable component. The executable imports a TH generator from its own
  library and runs a declaration splice in `app/Main.hs`. This checks both
  executable-component dependency discovery and host-side visibility of source
  modules from the same package;
- `consumer-ghc9103-cross-executable-qemu-smoke` runs the aarch64 executable
  from `consumer-ghc9103-cross-executable-package` under `qemu-aarch64` and
  checks that it prints `"Ada"`;
- `consumer-ghc9103-plugin` comes from `consumerGhc9103HaskellPkgs` and is
  built with GHC 9.10.3;
- `consumer-ghc9103-ghc` is a `consumerGhc9103HaskellPkgs` GHC environment
  containing `th-cross-plugin`;
- `checks.${system}.consumer-ghc9103-worker-smoke` compiles `Example.hs` with
  `consumer-ghc9103-ghc` and passes the Nix-built patched GHC 9.10.3 worker to the
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
TH_HOST_GHC_LIBDIR=/nix/store/...-patched-ghc-9.10.3/lib/ghc-9.10.3/lib
```

This prevents the worker from discovering an unrelated GHC via `PATH`
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
packages such as `base` and `template-haskell`, and builds a GHC 9.10.3
`ghcWithPackages` environment for those names. For example,
`consumer-ghc9103-cross-microlens-package` derives `microlens` and
`microlens-th`, then passes the matching libdir to the worker wrapper:

```text
TH_HOST_GHC_LIBDIR=/nix/store/...-ghc-9.10.3-with-packages/lib/ghc-9.10.3/lib
```

The same derived names are resolved through the host GHC package DB with
`ghc-pkg field <package> id --simple-output`, then passed as exact host package
exposure through plugin options:

```text
-fplugin-opt=THCross.Plugin:host-package-id=microlens-0.4.14.0-...
-fplugin-opt=THCross.Plugin:host-package-id=microlens-th-0.4.3.17-...
```

The plugin serializes these unit ids into the binary-framed splice request as
`hostPackageIds`. The worker turns them into host-side `-package-id` flags
before loading the source module. `TH_HOST_GHC_PACKAGE_IDS` is accepted as an
environment-variable fallback for manual experiments, but the preferred
prototype path is exact unit-id data from the cross-side plugin.

This uses nixpkgs' own evaluation-time Haskell dependency metadata instead of
parsing the `.cabal` file directly. It still assumes that each extracted package
`pname` is available under the same attribute name in
the GHC 9.10.3 host package set. Resolving the final GHC unit id through host
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
nix build .#host-ghc9103-worker
```

Build the consumer-side plugin with GHC 9.10.3:

```bash
nix build .#consumer-ghc9103-plugin
```

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

The source-level analysis and workaround investigation is recorded in
`docs/plain-nixpkgs-cross-ghc.md`.  The final working patch set and its
upstream status are documented in `docs/ghc-cross-patches.md`.

The patched cross-GHC is built as:

```bash
nix build .#cross-ghc9103-aarch64-linux
```

Build the consumer GHC environment:

```bash
nix build .#consumer-ghc9103-ghc
```

Build the package-level consumer example:

```bash
nix build .#consumer-ghc9103-package
```

Run the package through nixpkgs' Haskell generic builder:

```bash
nix build .#consumer-ghc9103-cross-generic-package -L --allow-import-from-derivation
find -L result -maxdepth 7 \( -type f -o -type l \) | sort
```

Observed result: the generic builder invokes the patched
`aarch64-unknown-linux-gnu-ghc-9.10.3`, loads `THCross.Plugin` through
`-fplugin-library`, starts the patched GHC 9.10.3 host worker, expands the expression
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

Observed result: the package builds an aarch64 executable component. The worker
receives the source directory of the current splice file plus every
`hs-source-dirs` entry parsed from the package `.cabal` file during
`preConfigure`, for example:

```text
th-host-worker: import paths ["app","/build/th-executable-consumer/src","/build/th-executable-consumer/app"]
```

The executable splice imports `ExecutableConsumer.Gen` from the same package
library and evaluates the generator through the host worker. The automatic host
package mechanism also derives external package names from both library and
executable component dependencies while filtering the package's own internal
library dependency out of the external host package set.

The source-directory data is deliberately derived from Cabal syntax instead of
hardcoded Nix metadata. The generic-builder wrapper compiles
`nix/tools/dump-cabal-source-dirs.hs` with the native Cabal library, runs it in
the unpacked package directory, extracts `hs-source-dirs` from library,
executable, test, and benchmark components, and embeds each directory into the
fourth field of `-fplugin-library` as `host-source-dir=...`. Separate
`-fplugin-opt=THCross.Plugin:...` arguments are not used on this path, because
external plugins loaded through `-fplugin-library` receive the option list from
the `-fplugin-library` argument.

The same path now derives unconditional Cabal `cpp-options` with
`nix/tools/dump-cabal-cpp-options.hs`. Each extracted option is embedded into
the plugin option list as:

```text
host-ghc-option=<cpp option>
```

The `th-consumer-example` package uses this for a CPP-sensitive splice:
`Example` defines either `TargetPlatform` or `HostPlatform`, and the splice
reifies `Platform` through the host worker. The package-level cross build only
passes because Cabal's `cpp-options: -DTH_CONSUMER_TARGET_CONTEXT` is forwarded
to the worker, causing the host-side expansion to return `TargetPlatform`, the
constructor visible to the cross compiler.

This is still intentionally limited. The current dumper reads unconditional
fields from the `.cabal` syntax; it does not yet preserve Cabal conditional
resolution, generated include directories, `autogen` CPP macros, or arbitrary
tool-specific preprocessing flags from `setup-config`.

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

Current blocker: host-side dependency context derivation is validated against
Cabal `setup-config`, but package selection is still not a complete Cabal
component-context model. The Nix experiment reads nixpkgs Haskell derivation
`passthru.getCabalDeps`, extracts dependency `pname`s, builds a matching GHC
9.8.4 host package DB, resolves exact host unit ids with host `ghc-pkg`, and
passes matching `host-package-id` plugin options automatically. A production
integration still needs a model for renamed packages, internal libraries beyond
the current package, setup dependencies, and packages whose host package-set
attribute is not the same as the Cabal package name.

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
  -> /nix/store host worker built with patched GHC 9.10.3
  -> raw TH expression expansion
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
- the plugin delegates TH execution to the patched native GHC 9.10.3 worker;
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
ghc-9.10.3
ghc-9.10.3-pkg
th-cross-build
th-cross-test
```

The test helpers use the Nix-built wrapped `host-ghc9103-worker`, so callers do
not need to set `TH_HOST_GHC_LIBDIR` manually.

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
th-cross-build th-cross-plugin
```

`th-host-worker` must be built through Nix because it depends on the patched
GHC API:

```bash
nix build .#host-ghc9103-worker
```

Run the integration test:

```bash
th-cross-test
```

By default this runs:

```bash
th-cross-test th-cross-plugin:integration --test-show-details=direct
```

The explicit `direct` mode is intentional: the integration suite takes about a
minute and should print each test case as it runs instead of looking stuck after
`Test suite integration: RUNNING...`.

The helper builds the patched worker through Nix before invoking `cabal test`
and exports it as:

```text
TH_HOST_WORKER=/nix/store/...-th-host-worker/bin/th-host-worker
```

This is deliberately done outside the test executable. Calling `cabal build`
from inside a `cabal test` process can wait on Cabal's own build/store locks and
look like a hung test suite.

The integration suite includes exact-name payload tests whose fixtures use
names that are intentionally not exported by their defining modules. Textual
splice replay is expected to be fragile for these shapes; the raw protocol
carries the resolved `TH.Name` in the binary payload and lets the cross-side
compiler convert the raw `TH.Exp`, `TH.Pat`, `TH.Type`, or `[TH.Dec]` directly.

The build helper is equivalent to:

```bash
cabal \
  --store-dir "$PWD/.cabal-store-nix" \
  build \
  --project-dir prototype \
  --builddir dist-newstyle-nix \
  --with-compiler ghc-9.10.3 \
  --with-hc-pkg ghc-9.10.3-pkg \
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
