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

        (
          cd ../../examples/target-context/nix/generated
          ${pkgs.cabal2nix}/bin/cabal2nix ../.. \
            > th-target-context-consumer.nix
        )

        (
          cd ../../examples/microlens/nix/generated
          ${pkgs.cabal2nix}/bin/cabal2nix ../.. \
            > th-microlens-consumer.nix
        )

        (
          cd ../../examples/aeson/nix/generated
          ${pkgs.cabal2nix}/bin/cabal2nix ../.. \
            > th-aeson-consumer.nix
        )

        (
          cd ../../examples/executable/nix/generated
          ${pkgs.cabal2nix}/bin/cabal2nix ../.. \
            > th-executable-consumer.nix
        )

        (
          cd ../../examples/dependency-th/dependency/nix/generated
          ${pkgs.cabal2nix}/bin/cabal2nix ../.. \
            > th-splice-dependency.nix
        )

        (
          cd ../../examples/dependency-th/consumer/nix/generated
          ${pkgs.cabal2nix}/bin/cabal2nix ../.. \
            > th-dependency-consumer.nix
        )

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
