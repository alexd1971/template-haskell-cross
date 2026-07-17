#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
prototype_dir="$(cd -- "${script_dir}/.." && pwd)"
work_dir="${prototype_dir}/dist-newstyle/cross-version-plugin-test"

host_ghc="${HOST_GHC:-ghc-9.8.4}"
consumer_ghc="${CONSUMER_GHC:-ghc-9.10.2}"

plugin_project="${work_dir}/plugin-ghc910.project"
consumer_build_dir="${work_dir}/consumer-build"
fixtures_dir="${prototype_dir}/th-cross-plugin/test/fixtures"
fixture_name="${FIXTURE:-Example.hs}"
fixture="${fixtures_dir}/${fixture_name}"
expected_exit="${EXPECT_EXIT:-success}"

if [[ "${expected_exit}" != "success" && "${expected_exit}" != "failure" ]]; then
  echo "EXPECT_EXIT must be either success or failure" >&2
  exit 1
fi

mkdir -p \
  "${work_dir}" \
  "${consumer_build_dir}"

cat > "${plugin_project}" <<EOF
packages: ${prototype_dir}/th-cross-plugin
EOF

cabal build \
  --project-dir "${prototype_dir}" \
  --with-compiler "${host_ghc}" \
  th-host-worker

worker_path="$(
  cabal list-bin \
    --project-dir "${prototype_dir}" \
    --with-compiler "${host_ghc}" \
    th-host-worker
)"

cabal build \
  --project-file="${plugin_project}" \
  --with-compiler="${consumer_ghc}" \
  th-cross-plugin

set +e
compile_output="$(
  cabal exec \
    --project-file="${plugin_project}" \
    --with-compiler="${consumer_ghc}" \
    -- \
    ghc \
      -v0 \
      -fno-code \
      -fforce-recomp \
      -package th-cross-plugin \
      -i"${fixtures_dir}" \
      -outputdir "${consumer_build_dir}" \
      -hidir "${consumer_build_dir}" \
      -odir "${consumer_build_dir}" \
      -stubdir "${consumer_build_dir}" \
      -fplugin=THCross.Plugin \
      -fplugin-opt=THCross.Plugin:worker="${worker_path}" \
      "${fixture}" \
    2>&1
)"
compile_status=$?
set -e

printf '%s\n' "${compile_output}"

case "${expected_exit}:${compile_status}" in
  success:0)
    ;;
  success:*)
    echo "expected successful compilation, got exit status ${compile_status}" >&2
    exit 1
    ;;
  failure:0)
    echo "expected compilation failure, got success" >&2
    exit 1
    ;;
  failure:*)
    ;;
esac

if ! grep -q "th-cross: intercepted Template Haskell splice" <<<"${compile_output}"; then
  echo "expected plugin interception log was not found" >&2
  exit 1
fi

if ! grep -q "worker: ${worker_path}" <<<"${compile_output}"; then
  echo "expected worker invocation log was not found" >&2
  exit 1
fi

echo "host GHC: $("${host_ghc}" --numeric-version)"
echo "consumer GHC: $("${consumer_ghc}" --numeric-version)"
echo "fixture: ${fixture_name}"
echo "compile exit: ${compile_status}"
echo "worker: ${worker_path}"
