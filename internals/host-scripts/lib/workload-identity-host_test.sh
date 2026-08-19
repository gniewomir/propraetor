#!/usr/bin/env bash
# Unit tests: Workload identity + reserved dial basenames (#233).
# Seam: workload_identity_require.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=workload-identity-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/workload-identity-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

workload_identity_require "web-api" || fail "valid basename must pass"
pass "valid basename accepted"

if workload_identity_require "database" 2>/dev/null; then
  fail "database dial basename must fail closed"
fi
pass "database reserved"

if workload_identity_require "cache" 2>/dev/null; then
  fail "cache dial basename must fail closed"
fi
pass "cache reserved"

if workload_identity_require "identity" 2>/dev/null; then
  fail "identity dial basename must fail closed"
fi
pass "identity reserved"

if workload_identity_require "../x" 2>/dev/null; then
  fail "path segment with slash must fail closed"
fi
if workload_identity_require ".hidden" 2>/dev/null; then
  fail "hidden basename must fail closed"
fi
pass "invalid identity shapes refused"

# --- Identity claim contract validation (#250) ---
TMP_ENV="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/wl-identity-contract-env.XXXXXX")"
trap 'rm -rf "${TMP_ENV}"' EXIT

mk_wl() {
  local dir="${1:?dir required}"
  local name="${2:?name required}"
  mkdir -p "${dir}"
  cat >"${dir}/manifest.json" <<EOF
{ "intent": "run", "source": "internal" }
EOF
  # Caller writes requires.json / provides.json.
  :
}

write_requires() {
  local dir="${1:?dir required}"
  cat >"${dir}/requires.json" <<'EOF'
{ "database": false, "cache": false, "identity": true }
EOF
}

write_provides_empty() {
  local dir="${1:?dir required}"
  printf '{}\n' >"${dir}/provides.json"
}

expect_fail_claim() {
  local wl_dir="${1:?wl_dir required}"
  local wl_name="${2:?wl_name required}"
  if workload_identity_claim_validate "${wl_dir}" "${wl_name}"; then
    fail "expected identity claim failure for ${wl_name}"
  fi
}

expect_pass_claim() {
  local wl_dir="${1:?wl_dir required}"
  local wl_name="${2:?wl_name required}"
  workload_identity_claim_validate "${wl_dir}" "${wl_name}" \
    || fail "expected identity claim pass for ${wl_name}"
}

WORKLOAD_NAME="wl0"

WORK1="${TMP_ENV}/missing-identity"
mk_wl "${WORK1}" "${WORKLOAD_NAME}"
cat >"${WORK1}/requires.json" <<'EOF'
{ "database": false, "cache": false }
EOF
cat >"${WORK1}/provides.json" <<'EOF'
{ "permissions": { "x:api": "API", "x:read": "Read" } }
EOF
expect_fail_claim "${WORK1}" "${WORKLOAD_NAME}"

WORK2="${TMP_ENV}/empty-catalog"
mk_wl "${WORK2}" "${WORKLOAD_NAME}"
cat >"${WORK2}/requires.json" <<'EOF'
{ "database": false, "cache": false, "identity": true }
EOF
cat >"${WORK2}/provides.json" <<'EOF'
{ "permissions": { } }
EOF
expect_fail_claim "${WORK2}" "${WORKLOAD_NAME}"

WORK3="${TMP_ENV}/missing-marker"
mk_wl "${WORK3}" "${WORKLOAD_NAME}"
cat >"${WORK3}/requires.json" <<'EOF'
{ "database": false, "cache": false, "identity": true }
EOF
cat >"${WORK3}/provides.json" <<'EOF'
{ "permissions": { "x:read": "Read" } }
EOF
expect_fail_claim "${WORK3}" "${WORKLOAD_NAME}"

WORK4="${TMP_ENV}/api-key-slug-mismatch"
mk_wl "${WORK4}" "${WORKLOAD_NAME}"
cat >"${WORK4}/requires.json" <<'EOF'
{ "database": false, "cache": false, "identity": true }
EOF
cat >"${WORK4}/provides.json" <<'EOF'
{ "permissions": { "x:api": "API", "y:read": "Read" } }
EOF
expect_fail_claim "${WORK4}" "${WORKLOAD_NAME}"

WORK5="${TMP_ENV}/invalid-api-key-shape"
mk_wl "${WORK5}" "${WORKLOAD_NAME}"
cat >"${WORK5}/requires.json" <<'EOF'
{ "database": false, "cache": false, "identity": true }
EOF
cat >"${WORK5}/provides.json" <<'EOF'
{ "permissions": { "x:api": "API", "x:read:extra": "Read" } }
EOF
expect_fail_claim "${WORK5}" "${WORKLOAD_NAME}"

WORK6="${TMP_ENV}/client-missing-permissions"
mk_wl "${WORK6}" "${WORKLOAD_NAME}"
cat >"${WORK6}/requires.json" <<'EOF'
{ "database": false, "cache": false, "identity": true }
EOF
cat >"${WORK6}/provides.json" <<'EOF'
{ "oidc_callback": "/cb" }
EOF
expect_fail_claim "${WORK6}" "${WORKLOAD_NAME}"

WORK7="${TMP_ENV}/client-invalid-key-shape"
mk_wl "${WORK7}" "${WORKLOAD_NAME}"
cat >"${WORK7}/requires.json" <<'EOF'
{ "database": false, "cache": false, "identity": true,
  "permissions": { "no-colon": "Bad" } }
EOF
cat >"${WORK7}/provides.json" <<'EOF'
{ "oidc_callback": "/cb" }
EOF
expect_fail_claim "${WORK7}" "${WORKLOAD_NAME}"

WORK8="${TMP_ENV}/identity-without-keys"
mk_wl "${WORK8}" "${WORKLOAD_NAME}"
cat >"${WORK8}/requires.json" <<'EOF'
{ "database": false, "cache": false, "identity": true }
EOF
cat >"${WORK8}/provides.json" <<'EOF'
{ }
EOF
expect_fail_claim "${WORK8}" "${WORKLOAD_NAME}"

WORK9="${TMP_ENV}/valid-both"
mk_wl "${WORK9}" "${WORKLOAD_NAME}"
cat >"${WORK9}/requires.json" <<'EOF'
{ "database": false, "cache": false, "identity": true,
  "permissions": { "x:read": "Read", "other:write": "Write" } }
EOF
cat >"${WORK9}/provides.json" <<'EOF'
{ "permissions": { "x:api": "API", "x:read": "Read" }, "oidc_callback": "/cb" }
EOF
expect_pass_claim "${WORK9}" "${WORKLOAD_NAME}"

# Environment uniqueness: permission key duplicates across API catalogs.
UNIQ_ENV="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/wl-identity-uniqueness.XXXXXX")"
trap 'rm -rf "${TMP_ENV}" "${UNIQ_ENV}"' EXIT

WL_A="${UNIQ_ENV}/catalog-A"
mk_wl "${WL_A}" "catalog-A"
cat >"${WL_A}/requires.json" <<'EOF'
{ "database": false, "cache": false, "identity": true }
EOF
cat >"${WL_A}/provides.json" <<'EOF'
{ "permissions": { "dup:api": "API", "dup:read": "Read" } }
EOF

WL_B="${UNIQ_ENV}/catalog-B"
mk_wl "${WL_B}" "catalog-B"
cat >"${WL_B}/requires.json" <<'EOF'
{ "database": false, "cache": false, "identity": true }
EOF
cat >"${WL_B}/provides.json" <<'EOF'
{ "permissions": { "dup:api": "API2", "dup:read": "Read2" } }
EOF

if environment_identity_permission_catalogs_validate "${UNIQ_ENV}" >/dev/null 2>&1; then
  fail "environment uniqueness must fail on duplicated API permission keys"
fi
pass "Identity claim validates fail-closed shapes and uniqueness"

# Operator and Host entrypoints must not inline the checks.
if grep -E 'basename .database. is reserved' \
  "${REPO_ROOT}/internals/ensure-workload.sh" \
  "${REPO_ROOT}/internals/host-scripts/ensure-workload-host.sh" \
  2>/dev/null; then
  fail "entrypoints must not duplicate reserved-basename checks"
fi
grep -Fq 'workload_identity_require' "${REPO_ROOT}/internals/ensure-workload.sh" \
  || fail "operator Setup must call workload_identity_require"
grep -Fq 'workload_setup_apply' \
  "${REPO_ROOT}/internals/host-scripts/ensure-workload-host.sh" \
  || fail "Host entry must call workload_setup_apply"
pass "identity not duplicated in entrypoints"

echo "All workload identity checks passed."
