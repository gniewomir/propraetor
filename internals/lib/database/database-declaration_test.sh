#!/usr/bin/env bash
# Offline tests: Manifest Database Declaration parse (ADR-0049 / #189).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=database-declaration.sh
source "${REPO_ROOT}/internals/lib/database/database-declaration.sh"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dbdecl.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
MANIFEST="${TMP}/manifest.json"

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run" }
EOF
got="$(database_declaration_claimed "${MANIFEST}")" || fail "omit should parse"
[[ "${got}" == "0" ]] || fail "omit should be unclaimed, got: ${got}"
pass "omit database → unclaimed"

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "database": false }
EOF
got="$(database_declaration_claimed "${MANIFEST}")" || fail "false should parse"
[[ "${got}" == "0" ]] || fail "false should be unclaimed, got: ${got}"
pass "database false → unclaimed"

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "database": true }
EOF
got="$(database_declaration_claimed "${MANIFEST}")" || fail "true should parse"
[[ "${got}" == "1" ]] || fail "true should be claimed, got: ${got}"
pass "database true → claimed"

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "database": "true" }
EOF
if database_declaration_claimed "${MANIFEST}" >/dev/null 2>&1; then
  fail "string database must fail closed"
fi
pass "non-boolean database fails closed"

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "database": 1 }
EOF
if database_declaration_claimed "${MANIFEST}" >/dev/null 2>&1; then
  fail "numeric database must fail closed"
fi
pass "numeric database fails closed"
