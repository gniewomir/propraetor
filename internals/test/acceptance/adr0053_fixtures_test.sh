#!/usr/bin/env bash
# Seam: Acceptance fixtures and teaching examples are ADR-0053 trees
# (thin Manifest + Provides + Requires + Binding). No live Host.
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${CASE_DIR}/../../.." && pwd)"
# shellcheck source=lib.sh
source "${CASE_DIR}/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

command -v python3 >/dev/null || fail "python3 required"

# --- teaching examples are Artifact + Binding, not retired Manifest keys ---
EXAMPLE_DIR="${REPO_ROOT}/environments/example"
[[ -d "${EXAMPLE_DIR}" ]] || fail "missing environments/example"
found=0
for tree in "${EXAMPLE_DIR}"/*; do
  [[ -d "${tree}" ]] || continue
  [[ -f "${tree}/manifest.json" ]] || continue
  found=$((found + 1))
  name="$(basename "${tree}")"
  acceptance_assert_artifact_tree "${tree}" "example ${name}"
  pass "example ${name} is thin Manifest + Provides/Requires/Binding"
done
[[ "${found}" -ge 5 ]] || fail "expected ≥5 teaching examples, found ${found}"

# sidecar teaching example is not a Database Component claimant
db_claim="$(
  python3 - "${EXAMPLE_DIR}/web-api-with-db/requires.json" <<'PY'
import json, sys
print("1" if json.load(open(sys.argv[1], encoding="utf-8")).get("database") else "0")
PY
)"
[[ "${db_claim}" == "0" ]] \
  || fail "web-api-with-db must Requires database:false (in-pod sidecar, not Database Component)"
pass "example web-api-with-db is not a Database claimant"

# --- helper fail-closed on retired Manifest keys ---
umask 077
TMP="$(mktemp -d "${TMPDIR:-/tmp}/adr0053-fixtures.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/retired-env"
acceptance_write_artifact_stubs "${TMP}/retired-env"
cat >"${TMP}/retired-env/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal", "environment": ["ENV_KEY"] }
EOF
if (acceptance_assert_artifact_tree "${TMP}/retired-env" "retired-env") >/dev/null 2>&1; then
  fail "Manifest environment must fail artifact-tree assert"
fi
pass "retired Manifest environment fails artifact-tree assert"

mkdir -p "${TMP}/retired-db"
acceptance_write_artifact_stubs "${TMP}/retired-db"
cat >"${TMP}/retired-db/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal", "database": true }
EOF
if (acceptance_assert_artifact_tree "${TMP}/retired-db" "retired-db") >/dev/null 2>&1; then
  fail "Manifest database must fail artifact-tree assert"
fi
pass "retired Manifest database fails artifact-tree assert"

mkdir -p "${TMP}/retired-cache"
acceptance_write_artifact_stubs "${TMP}/retired-cache"
cat >"${TMP}/retired-cache/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal", "cache": true }
EOF
if (acceptance_assert_artifact_tree "${TMP}/retired-cache" "retired-cache") >/dev/null 2>&1; then
  fail "Manifest cache must fail artifact-tree assert"
fi
pass "retired Manifest cache fails artifact-tree assert"

mkdir -p "${TMP}/ok"
acceptance_write_artifact_stubs "${TMP}/ok"
cat >"${TMP}/ok/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
acceptance_assert_artifact_tree "${TMP}/ok" "stub tree"
pass "thin stub tree passes artifact-tree assert"

echo "All ADR-0053 Acceptance fixture checks passed."
