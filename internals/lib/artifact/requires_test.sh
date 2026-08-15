#!/usr/bin/env bash
# Unit tests: Requires parse/validate (ADR-0053 / ADR-0055 / #220).
# Seam: artifact_requires_*.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=requires.sh
source "${REPO_ROOT}/internals/lib/artifact/requires.sh"
# shellcheck source=manifest.sh
source "${REPO_ROOT}/internals/lib/artifact/manifest.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/artifact-requires.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
REQUIRES="${TMP}/requires.json"
MANIFEST="${TMP}/manifest.json"

# --- valid ---
cat >"${REQUIRES}" <<'EOF'
{ "environment": {}, "database": false, "cache": false }
EOF
artifact_requires_validate "${REQUIRES}" || fail "minimal Requires must pass"
[[ "$(artifact_requires_database "${REQUIRES}")" == "0" ]] || fail "database false → 0"
[[ "$(artifact_requires_cache "${REQUIRES}")" == "0" ]] || fail "cache false → 0"
[[ -z "$(artifact_requires_environment "${REQUIRES}")" ]] || fail "empty env map"

cat >"${REQUIRES}" <<'EOF'
{
  "environment": { "API_KEY": "human description", "APP_URL": "Public URL" },
  "database": true,
  "cache": true
}
EOF
artifact_requires_validate "${REQUIRES}" || fail "full Requires must pass"
[[ "$(artifact_requires_database "${REQUIRES}")" == "1" ]] || fail "database true → 1"
[[ "$(artifact_requires_cache "${REQUIRES}")" == "1" ]] || fail "cache true → 1"
env_names="$(artifact_requires_environment "${REQUIRES}")"
printf '%s\n' "${env_names}" | grep -Fxq 'API_KEY' || fail "missing API_KEY"
printf '%s\n' "${env_names}" | grep -Fxq 'APP_URL' || fail "missing APP_URL"
[[ "$(printf '%s\n' "${env_names}" | wc -l | tr -d ' ')" == "2" ]] || fail "want 2 env names"

# Database-only claimant still valid with explicit cache:false
cat >"${REQUIRES}" <<'EOF'
{ "environment": {}, "database": true, "cache": false }
EOF
artifact_requires_validate "${REQUIRES}" || fail "database true + cache false must pass"
[[ "$(artifact_requires_database "${REQUIRES}")" == "1" ]] || fail "database-only → db 1"
[[ "$(artifact_requires_cache "${REQUIRES}")" == "0" ]] || fail "database-only → cache 0"
pass "valid Requires"

# --- fail closed ---
printf '{}\n' >"${REQUIRES}"
if artifact_requires_validate "${REQUIRES}" >/dev/null 2>&1; then
  fail "missing database must fail closed"
fi
cat >"${REQUIRES}" <<'EOF'
{ "environment": {}, "database": false }
EOF
if artifact_requires_validate "${REQUIRES}" >/dev/null 2>&1; then
  fail "missing cache must fail closed"
fi
cat >"${REQUIRES}" <<'EOF'
{ "environment": {}, "database": "true", "cache": false }
EOF
if artifact_requires_validate "${REQUIRES}" >/dev/null 2>&1; then
  fail "string database must fail closed"
fi
cat >"${REQUIRES}" <<'EOF'
{ "environment": {}, "database": false, "cache": "true" }
EOF
if artifact_requires_validate "${REQUIRES}" >/dev/null 2>&1; then
  fail "string cache must fail closed"
fi
cat >"${REQUIRES}" <<'EOF'
{ "environment": {}, "database": false, "cache": 1 }
EOF
if artifact_requires_validate "${REQUIRES}" >/dev/null 2>&1; then
  fail "numeric cache must fail closed"
fi
cat >"${REQUIRES}" <<'EOF'
{ "environment": { "X": 1 }, "database": false, "cache": false }
EOF
if artifact_requires_validate "${REQUIRES}" >/dev/null 2>&1; then
  fail "non-string env description must fail closed"
fi
cat >"${REQUIRES}" <<'EOF'
{ "environment": { "": "x" }, "database": false, "cache": false }
EOF
if artifact_requires_validate "${REQUIRES}" >/dev/null 2>&1; then
  fail "empty env name must fail closed"
fi
cat >"${REQUIRES}" <<'EOF'
{ "environment": [], "database": false, "cache": false }
EOF
if artifact_requires_validate "${REQUIRES}" >/dev/null 2>&1; then
  fail "environment array must fail closed"
fi
cat >"${REQUIRES}" <<'EOF'
{ "environment": {}, "database": false, "cache": false, "extra": 1 }
EOF
if artifact_requires_validate "${REQUIRES}" >/dev/null 2>&1; then
  fail "unknown Requires key must fail closed"
fi
pass "invalid Requires fails closed"

# --- Manifest does not declare Cache need (ADR-0055 / #220) ---
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "source": "internal", "cache": true }
EOF
if artifact_manifest_validate "${MANIFEST}" >/dev/null 2>&1; then
  fail "Manifest cache must fail closed"
fi
pass "Manifest does not declare Cache need"

echo "All artifact Requires offline tests passed."
