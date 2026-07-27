{ pkgs, hs, packages, testFixturesDir, aarch64LinuxCrossProbe }:

# Fast flake checks that exercise the already-supported native/plugin-worker
# combinations. Heavy cross-GHC builds are exposed as packages/experiments
# instead of mandatory checks.
{
  consumer-ghc9103-worker-smoke = pkgs.runCommand
    "th-cross-consumer-ghc9103-worker-smoke"
    { }
    ''
      build_dir="$TMPDIR/consumer-build"
      mkdir -p "$build_dir"

      ${hs.consumerGhc9103}/bin/ghc \
        -v0 \
        -fno-code \
        -fforce-recomp \
        -i${testFixturesDir} \
        -outputdir "$build_dir" \
        -hidir "$build_dir" \
        -odir "$build_dir" \
        -stubdir "$build_dir" \
        -fplugin=THCross.Plugin \
        -fplugin-opt=THCross.Plugin:worker=${packages.host-ghc9103-worker}/bin/th-host-worker \
        ${testFixturesDir + "/Example.hs"}

      touch "$out"
    '';

  consumer-ghc9103-target-context-package =
    hs.consumerGhc9103HaskellPkgs.th-target-context-consumer;

  cross-target-probe-aarch64-linux = aarch64LinuxCrossProbe;
}
