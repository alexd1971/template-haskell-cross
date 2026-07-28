{
  description = "Template Haskell cross-compilation support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    import ./nix/flake {
      inherit self nixpkgs;
    };
}
