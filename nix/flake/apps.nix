{ pkgs }:

# Flake apps are developer-maintenance commands. They should not contain package
# or experiment logic; keep those in package-set or experiment modules.
{
  regen-cabal-nix =
    let
      updateScript = pkgs.writeShellScriptBin "th-cross-regen-cabal-nix" ''
        set -euo pipefail

        mkdir -p nix/generated

        ${pkgs.cabal2nix}/bin/cabal2nix prototype/th-cross-plugin \
          > nix/generated/th-cross-plugin.nix

        ${pkgs.cabal2nix}/bin/cabal2nix prototype/th-host-worker \
          > nix/generated/th-host-worker.nix

        ${pkgs.cabal2nix}/bin/cabal2nix prototype/th-consumer-example \
          > nix/generated/th-consumer-example.nix

        ${pkgs.cabal2nix}/bin/cabal2nix prototype/th-microlens-consumer \
          > nix/generated/th-microlens-consumer.nix

        ${pkgs.cabal2nix}/bin/cabal2nix prototype/th-executable-consumer \
          > nix/generated/th-executable-consumer.nix
      '';
    in
    {
      type = "app";
      program = "${updateScript}/bin/th-cross-regen-cabal-nix";
      meta.description = "Regenerate checked-in Cabal-derived Nix expressions";
    };
}
