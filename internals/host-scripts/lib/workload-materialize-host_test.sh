#!/usr/bin/env bash
# Unit tests: Host Workload materialize projection (ADR-0053 / #204).
# Seam: workload_materialize_tree.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=workload-materialize-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/workload-materialize-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/wl-materialize.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

OUT="${TMP}/out"
TREE="${TMP}/env-wl"
mkdir -p "${TREE}"
printf '{}\n' >"${TREE}/binding.json"
cat >"${TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": "http://127.0.0.1:1/missing.zip" }
EOF

# Zip Environment must not already hold Artifact contracts (fail before fetch).
printf '{ "database": false }\n' >"${TREE}/requires.json"
if err="$(workload_materialize_tree "${TREE}" "${OUT}" 2>&1)"; then
  fail "zip Environment requires.json must fail closed before zip fetch"
fi
printf '%s\n' "${err}" | grep -q 'requires.json' \
  || fail "zip dest collision must name requires.json, got: ${err}"
printf '%s\n' "${err}" | grep -Eqi 'fetch|curl' \
  && fail "zip dest collision must fail before fetch, got: ${err}"
pass "zip Environment requires.json fails closed before fetch"

rm -f "${TREE}/requires.json"
printf '{}\n' >"${TREE}/provides.json"
if err="$(workload_materialize_tree "${TREE}" "${OUT}" 2>&1)"; then
  fail "zip Environment provides.json must fail closed before zip fetch"
fi
printf '%s\n' "${err}" | grep -q 'provides.json' \
  || fail "zip dest collision must name provides.json, got: ${err}"
pass "zip Environment provides.json fails closed before fetch"

echo "All workload-materialize-host offline tests passed."
