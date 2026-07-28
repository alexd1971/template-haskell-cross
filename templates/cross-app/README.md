# Cross app

This is a scaffold for a package that uses Template Haskell while being
cross-compiled through `th-cross`. It includes a small executable and an
`aeson` `deriveJSON` splice as an example real TH dependency.

After creating a project from this template, edit `flake.nix` and replace:

```nix
th-cross.url = "path:/path/to/th-cross";
```

with the actual location of your `th-cross` checkout or remote flake.

Build:

```bash
nix build . -L
```

If you edit the Cabal file, regenerate the package expression:

```bash
cabal2nix . > nix/generated/cross-app.nix
```
