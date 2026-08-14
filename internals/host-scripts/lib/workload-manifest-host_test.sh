#!/usr/bin/env bash
# Unit tests: Host Workload Manifest Intent reader.
# Seam: workload_manifest_intent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=workload-manifest-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/workload-manifest-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/wl-manifest.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
MANIFEST="${TMP}/manifest.json"

# --- intent ---
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run" }
EOF
[[ "$(workload_manifest_intent "${MANIFEST}")" == "run" ]] || fail "run intent"
cat >"${MANIFEST}" <<'EOF'
{ "intent": "stop" }
EOF
[[ "$(workload_manifest_intent "${MANIFEST}")" == "stop" ]] || fail "stop intent"
cat >"${MANIFEST}" <<'EOF'
{ "intent": "trash" }
EOF
[[ "$(workload_manifest_intent "${MANIFEST}")" == "trash" ]] || fail "trash intent"
pass "intent run|stop|trash"

cat >"${MANIFEST}" <<'EOF'
{ "intent": "paused" }
EOF
if workload_manifest_intent "${MANIFEST}" >/dev/null 2>&1; then
  fail "unknown intent must fail closed"
fi
cat >"${MANIFEST}" <<'EOF'
{}
EOF
if workload_manifest_intent "${MANIFEST}" >/dev/null 2>&1; then
  fail "missing intent must fail closed"
fi
pass "intent fails closed on bad/missing"

# --- Manifest database claim reader is retired (#202) ---
if grep -F 'workload_manifest_database_claimed' \
  "${REPO_ROOT}/internals/host-scripts/lib/workload-manifest-host.sh" \
  "${REPO_ROOT}/internals/host-scripts/lib/database-fulfill-host.sh" \
  2>/dev/null; then
  fail "Manifest database claim reader must be deleted (Requires owns claim)"
fi
if grep -E '^_edge_read_workload_intent\(\)|^_database_read_workload_intent\(\)|^_database_manifest_claims\(\)' \
  "${REPO_ROOT}/internals/host-scripts/lib/edge-routes-host.sh" \
  "${REPO_ROOT}/internals/host-scripts/lib/database-fulfill-host.sh" \
  2>/dev/null; then
  fail "private Intent readers must be removed from Edge/Database libs"
fi
[[ ! -e "${REPO_ROOT}/internals/lib/database/database-declaration.sh" ]] \
  || fail "operator database-declaration.sh must be deleted"
[[ ! -e "${REPO_ROOT}/internals/lib/database/database-declaration_test.sh" ]] \
  || fail "operator database-declaration_test.sh must be deleted"
pass "duplicates deleted; callers use Host Manifest module"

echo "All workload-manifest-host offline tests passed."
