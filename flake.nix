{
  description = "Template Haskell cross-compilation prototype";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    import ./nix/flake {
      inherit self nixpkgs;
    };
}
