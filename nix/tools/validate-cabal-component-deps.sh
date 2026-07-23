set -euo pipefail

cabal_component_deps=$1
expected_packages=$2
excluded_packages=$3
nix_support_dir=$4

actual_packages="$nix_support_dir/cabal-derived-package-names"
expected_packages_normalized="$nix_support_dir/nix-derived-host-package-names.sorted"
package_name_diff="$nix_support_dir/package-name-diff"

# `expected_packages` is the package-name set selected during Nix evaluation.
# This set is used to build the host GHC 9.8.4 package DB for the worker.
sed '/^$/d' "$expected_packages" \
  | sort -u \
  > "$expected_packages_normalized"

# `actual_packages` is the package-name set Cabal resolved during
# `Setup configure`, read back from `dist/setup-config`.
#
# `excluded_packages` contains packages that are either built into the host GHC
# environment (`base`, `template-haskell`) or are the package's own internal
# components. Those must not be added as external worker dependencies.
awk '/^  / { print $1 }' "$cabal_component_deps" \
  | { grep -F -x -v -f "$excluded_packages" || true; } \
  | sort -u \
  > "$actual_packages"

if ! diff -u \
  "$expected_packages_normalized" \
  "$actual_packages" \
  > "$package_name_diff"; then
  echo "Nix-derived host package names differ from Cabal setup-config package names" >&2
  cat "$package_name_diff" >&2
  exit 1
fi
