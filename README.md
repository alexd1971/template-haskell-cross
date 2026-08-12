# template-haskell-cross

Cross-compilation support for Haskell packages that use Template Haskell,
built as a set of Nix flake helpers.

## The problem

Template Haskell splices run at compile time, on the machine doing the
compiling. When cross-compiling (say, building for `aarch64-linux` or Android
on an `x86_64-linux` build machine), the cross-GHC produces target code but
cannot itself *execute* target code to run a splice. The traditional GHC
answer is a remote `iserv`: ship the compiled splice to an emulator or a real
target device and run it there. That drags emulators (`qemu-user`) or device
access into the build, and still does not help when the target has no way to
run arbitrary code at all (e.g. iOS, Android without root access to the build
graph).

`template-haskell-cross` avoids that path entirely. It runs splices as plain native code on
the *host* — the same machine running the compiler — through a small
out-of-process worker, and feeds the resulting `template-haskell` AST back
into the cross-GHC compilation. No emulator, no textual pretty-print/reparse
round-trip (which breaks on real TH output referencing internal/non-exported
names, e.g. from `aeson`), no target-side interpreter.

This makes ordinary TH-using packages (`aeson`, `microlens-th`, custom
`Language.Haskell.TH` generators, etc.) buildable for cross targets without
modifying the package itself.

## Architecture

```text
host worker:        native patched GHC + th-host-worker executable
                     runs the actual TH splice, using host-side dependencies

consumer plugin:     native GHC + th-cross-plugin (a GHC plugin, loaded via
                     -fplugin-library) + th-cross-protocol
                     intercepts splices in the cross-GHC process and asks the
                     host worker to evaluate them

target package set:  patched cross-GHC + target dependencies
                     compiles the package for the target, consuming the raw
                     TH AST produced by the worker instead of running the
                     splice itself
```

The worker and the plugin exchange binary-encoded `template-haskell` AST
values, so they must come from the *same* GHC/`template-haskell` version —
see "Supported GHC versions" below. Full protocol details are in
[`docs/protocol.md`](docs/protocol.md); the complete Nix wiring is in
[`docs/nix-integration.md`](docs/nix-integration.md).

## Supported GHC versions and targets

Validated GHC patch releases (each needs an explicit compiler profile in
`nix/flake/ghc-profiles.nix` plus a validation run — a version is not
supported just because it belongs to a "supported series"):

| Series | Validated patch release |
| --- | --- |
| 9.8.x | 9.8.4 |
| 9.10.x | 9.10.3 |
| 9.12.x | 9.12.4 |

Target platforms (`nix/flake/target-profiles.nix`):

| Target | Status |
| --- | --- |
| `aarch64-linux` | Validated with all examples, all supported GHC versions |
| `aarch64-android` | Validated with all examples, GHC 9.10.3 |
| `iphone64` (iOS device) | Experimental; blocked on `Xcode.app` availability, see `docs/nix-integration.md` |

Details and the version-compatibility matrix: [`docs/ghc-version-support.md`](docs/ghc-version-support.md).
Build-system outputs (the machine running Nix) currently cover
`x86_64-linux` and `aarch64-darwin`.

## Using it in a real project

The integration is Nix-side only. Your `.cabal` file stays the source of
truth; you generate a `cabal2nix` expression for it and wrap that expression
with `th-cross`'s `buildPackage` helper, picking one explicit, validated GHC
version and target.

### Starting a new package

```bash
nix flake init -t github:alexd1971/template-haskell-cross#cross-app
```

This scaffolds an executable, a small library, and an `aeson` `deriveJSON`
splice as a working TH example. Edit `th-cross.url` in the generated
`flake.nix` if you need a local checkout, then:

```bash
nix build . -L
```

### Adding it to an existing package

Minimal layout — add only the Nix wrapper next to your existing package:

```text
my-package/
  flake.nix
  my-package.cabal
  src/...
  nix/generated/my-package.nix
```

```bash
mkdir -p nix/generated
cabal2nix . > nix/generated/my-package.nix
```

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    th-cross.url = "github:alexd1971/template-haskell-cross";
  };

  outputs = { th-cross, ... }:
    let
      system = "x86_64-linux";
      thCross = th-cross.lib.${system}.mkCrossFor {
        ghcVersion = "9.10.3";
        target = "aarch64-linux";
      };
    in
    {
      packages.${system}.default =
        thCross.buildPackage {
          packageFile = ./nix/generated/my-package.nix;
        };
    };
}
```

```bash
nix build . -L
```

Change `ghcVersion` or `target` directly in `flake.nix` to retarget the
build — this keeps CI and local builds deterministic (the environment
variable pattern used by this repository's own example matrix is a
maintenance convenience, not the recommended shape for consumer projects).

Rules of thumb:

- Keep `template-haskell` and any TH-generating libraries (`aeson`,
  `microlens-th`, ...) in normal Cabal `build-depends`; `buildPackage` derives
  the host worker's package environment from that metadata automatically.
- Regenerate `nix/generated/my-package.nix` with `cabal2nix` whenever
  dependencies, components, `hs-source-dirs`, or Cabal conditionals change.
- A local dependency package that itself uses TH can be built the same way
  and passed in via `packageArgs`; see
  [`docs/external-project-integration.md`](docs/external-project-integration.md#dependency-rules).
- If a build fails with a dependency-graph mismatch, build the diagnostic
  probe: `thCross.checkCabalContext ./nix/generated/my-package.nix`, then
  inspect `result/nix-support/*`.

Full walkthrough, including version-mismatch handling and troubleshooting:
[`docs/external-project-integration.md`](docs/external-project-integration.md).

Browser/WASM support is currently research-only. The latest notes and
constraints are recorded in [`docs/wasm-browser-research.md`](docs/wasm-browser-research.md).

## Flake outputs

| Output | Purpose |
| --- | --- |
| `lib.${system}.mkCrossFor` | Public API: build target packages for a chosen GHC version/target (see above) |
| `lib.${system}.supportedGhcVersions`, `supportedTargets` | Introspection of validated versions/targets |
| `lib.${system}.internal` | Escape hatch for repository maintenance/diagnostics; not part of the consumer API |
| `templates.cross-app` / `templates.default` | `nix flake init -t` scaffold for new packages |
| `devShells.${system}.default` | Contributor shell for this repository (Cabal-based iteration, per-GHC wrappers) |
| `checks.${system}.*` | Smoke test exercising the same `mkCrossFor`/`buildPackage` path consumers use |
| `apps.${system}.regen-cabal-nix` | Maintenance command regenerating checked-in `cabal2nix` expressions |

There is intentionally no root `packages` output — this repository only
ships the reusable library, not a package for direct installation.

The value returned by `mkCrossFor` also exposes `targetGhc` and
`targetGhcDynObjectArchives` for embedders that need target compiler runtime
artifacts. `targetGhcDynObjectArchives` contains archives built from preserved
GHC boot-package `.dyn_o` files and is intended for static-Haskell embedding
integrations.

## Repository layout

```text
protocol/    shared types for the worker <-> plugin wire protocol
plugin/      th-cross-plugin: GHC plugin loaded into the cross-GHC process
worker/      th-host-worker: native executable that runs splices
nix/         flake wiring: compiler profiles, target profiles, th-cross-lib
nix/tools/   th-cross-nix-tool: Cabal/package-db inspection helper used by the Nix wiring
examples/    consumer flakes exercised as fixtures (aeson, microlens, executable, ...)
templates/   `nix flake init` scaffold (cross-app)
docs/        architecture, protocol, and integration reference docs
```

## Development

```bash
nix develop        # contributor shell: ghc-<version>, th-cross-build, th-cross-test
nix flake check    # fast smoke check
nix run .#regen-cabal-nix   # regenerate nix/generated/*.nix from Cabal files
```

See [`docs/nix-integration.md`](docs/nix-integration.md) for the full
development workflow, including running examples against non-default GHC
versions/targets.

## License

BSD 3-Clause, see [`LICENSE`](LICENSE).
