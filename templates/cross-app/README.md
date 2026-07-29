# Cross app

This is a scaffold for a package that uses Template Haskell while being
cross-compiled through `th-cross`. It includes a small executable and an
`aeson` `deriveJSON` splice as an example real TH dependency.

After creating a project from this template, edit `flake.nix` if you need a
local checkout instead of the default GitHub input:

```nix
th-cross.url = "github:alexd1971/template-haskell-cross";
```

For local development, use:

```nix
th-cross.url = "path:/path/to/template-haskell-cross";
```

Build:

```bash
nix build . -L
```

If you edit the Cabal file, regenerate the package expression:

```bash
cabal2nix . > nix/generated/cross-app.nix
```
