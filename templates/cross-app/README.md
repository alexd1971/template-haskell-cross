# Cross app

This is a scaffold for a package that uses Template Haskell while being
cross-compiled through `th-cross`. It includes a small executable and an
`aeson` `deriveJSON` splice as an example real TH dependency.

After creating a project from this template, rename the package: replace
`cross-app` with your package name in `cross-app.cabal` (`name:`,
`executable cross-app`), in `nix/generated/cross-app.nix` (`pname`,
`mainProgram`), and in the `packageFile` path referenced from `flake.nix`.
Also rename the `App.Payload` module to match your own code.

Edit `flake.nix` if you need a local checkout of `th-cross` instead of the
default GitHub input:

```nix
th-cross.url = "github:alexd1971/template-haskell-cross";
```

For local development, use:

```nix
th-cross.url = "path:/path/to/template-haskell-cross";
```

`ghcVersion` and `target` are set directly in `flake.nix`; edit them there to
pick a different supported GHC version or cross target:

```nix
ghcVersion = "9.10.3";
target = "aarch64-linux";
```

Build:

```bash
nix build . -L
```

If you edit the Cabal file, regenerate the package expression:

```bash
cabal2nix . > nix/generated/cross-app.nix
```

Commit `flake.lock` once it is generated, so the build stays reproducible.
