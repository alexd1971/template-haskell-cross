{ pkgs }:

# Flake apps are developer-maintenance commands. They should not contain package
# or experiment logic; keep those in package-set or experiment modules.
{
  regen-cabal-nix =
    let
      updateScript = pkgs.writeShellScriptBin "th-cross-regen-cabal-nix" ''
        set -euo pipefail

        repo_root="$PWD"
        mkdir -p "$repo_root/nix/generated"

        ${pkgs.cabal2nix}/bin/cabal2nix "$repo_root/prototype/th-cross-plugin" \
          > "$repo_root/nix/generated/th-cross-plugin.nix"

        ${pkgs.cabal2nix}/bin/cabal2nix "$repo_root/prototype/th-host-worker" \
          > "$repo_root/nix/generated/th-host-worker.nix"

        ${pkgs.cabal2nix}/bin/cabal2nix "$repo_root/prototype/th-consumer-example" \
          > "$repo_root/nix/generated/th-consumer-example.nix"
      '';
    in
    {
      type = "app";
      program = "${updateScript}/bin/th-cross-regen-cabal-nix";
      meta.description = "Regenerate checked-in Cabal-derived Nix expressions";
    };
}
