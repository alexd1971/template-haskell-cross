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
}
