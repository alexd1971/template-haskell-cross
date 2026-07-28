{ pkgs }:

# Flake apps are developer-maintenance commands. They should not contain package
# or experiment logic; keep those in package-set or experiment modules.
{
  regen-cabal-nix =
    let
      updateScript = pkgs.writeShellScriptBin "th-cross-regen-cabal-nix" ''
        set -euo pipefail

        mkdir -p nix/generated
        cd nix/generated

        ${pkgs.cabal2nix}/bin/cabal2nix ../../protocol \
          > th-cross-protocol.nix

        ${pkgs.cabal2nix}/bin/cabal2nix ../../plugin \
          > th-cross-plugin.nix

        ${pkgs.cabal2nix}/bin/cabal2nix ../../worker \
          > th-host-worker.nix

        ${pkgs.cabal2nix}/bin/cabal2nix ../../consumer/target-context \
          > th-target-context-consumer.nix

        ${pkgs.cabal2nix}/bin/cabal2nix ../../consumer/microlens \
          > th-microlens-consumer.nix

        ${pkgs.cabal2nix}/bin/cabal2nix ../../consumer/aeson \
          > th-aeson-consumer.nix

        ${pkgs.cabal2nix}/bin/cabal2nix ../../consumer/executable \
          > th-executable-consumer.nix

        ${pkgs.cabal2nix}/bin/cabal2nix ../../nix/tools \
          > th-cross-nix-tools.nix
      '';
    in
    {
      type = "app";
      program = "${updateScript}/bin/th-cross-regen-cabal-nix";
      meta.description = "Regenerate checked-in Cabal-derived Nix expressions";
    };
}
