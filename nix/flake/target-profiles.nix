{ pkgs }:

# Target profiles describe only target-platform policy. Compiler-version policy
# lives in `ghc-profiles.nix`.
#
# Required fields:
# - `crossPkgs`: nixpkgs cross package set for the target.
# - `targetName`: GHC target name used while building the cross compiler.
# - `targetTriple`: executable prefix used by the installed cross GHC tools.
#
# Optional field:
# - `haskellPackageOverrides`: target-specific overrides composed into the
#   target Haskell package set before the TH plugin wrapper is applied.
{
  "aarch64-linux" = {
    crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
    targetName = "aarch64-linux";
    targetTriple = "aarch64-unknown-linux-gnu";
  };

  "aarch64-android" = {
    crossPkgs = pkgs.pkgsCross.aarch64-android-prebuilt;
    targetName = "aarch64-android";
    targetTriple = "aarch64-unknown-linux-android";
    haskellPackageOverrides = _: super: {
      mkDerivation = args:
        super.mkDerivation
          (args // {
            enableSharedLibraries = true;
            preFixup = (args.preFixup or "") + ''
              # Android shared Haskell libraries can inherit temporary
              # build-package-db paths in RPATH. Remove only TMPDIR RPATH
              # entries before nixpkgs' audit-tmpdir hook runs.
              while IFS= read -r -d "" elf; do
                old_rpath="$(patchelf --print-rpath "$elf" 2>/dev/null || true)"
                if [ -z "$old_rpath" ]; then
                  continue
                fi

                new_rpath="$(printf '%s' "$old_rpath" | tr ':' '\n' | awk -v tmpdir="$TMPDIR/" 'index($0, tmpdir) != 1' | paste -sd: -)"
                if [ "$new_rpath" = "$old_rpath" ]; then
                  continue
                fi

                if [ -z "$new_rpath" ]; then
                  patchelf --remove-rpath "$elf"
                else
                  patchelf --set-rpath "$new_rpath" "$elf"
                fi
              done < <(find "$out" -type f -print0)
            '';
          });
    };
  };

  "iphone64" = let
    baseCrossPkgs = pkgs.pkgsCross.iphone64;
    appleSdkCupsHeaders = baseCrossPkgs."apple-sdk".cups-headers;
  in {
    crossPkgs =
      baseCrossPkgs.appendOverlays [
        (_: previous: {
          # nixpkgs' iOS cross package set has target `ncurses = null`, while
          # apple-sdk's default propagation phase unconditionally tries to copy
          # ncurses headers into the SDK. Use the existing bootstrap SDK mode to
          # skip that propagation, but keep the `cups-headers` passthru expected
          # by Darwin stdenv's allowed-requisites check.
          "apple-sdk" =
            (previous."apple-sdk".override { enableBootstrap = true; }).overrideAttrs (old: {
              passthru = (old.passthru or { }) // {
                cups-headers = appleSdkCupsHeaders;
              };
            });
        })
      ];
    targetName = "arm64-apple-ios";
    targetTriple = "arm64-apple-ios";
  };
}
