#!/usr/bin/env bash
# Unit tests: Provides parse + reserved destination collision (ADR-0053 / #199).
# Seam: artifact_provides_* / artifact_reserved_*.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=provides.sh
source "${REPO_ROOT}/internals/lib/artifact/provides.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/artifact-provides.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
PROVIDES="${TMP}/provides.json"

# --- valid empty / omit ---
printf '{}\n' >"${PROVIDES}"
artifact_provides_validate "${PROVIDES}" || fail "empty Provides must be valid"
[[ -z "$(artifact_provides_directories "${PROVIDES}")" ]] \
  || fail "empty Provides directories must print nothing"
[[ -z "$(artifact_provides_routes "${PROVIDES}")" ]] \
  || fail "empty Provides routes must print nothing"
pass "empty Provides"

cat >"${PROVIDES}" <<'EOF'
{
  "permissions": {
    "api-a:read": "Read permission"
  }
}
EOF
artifact_provides_validate "${PROVIDES}" || fail "Provides.permissions must be valid"
pass "valid Provides.permissions"

cat >"${PROVIDES}" <<'EOF'
{
  "oidc_callback": "/callback"
}
EOF
artifact_provides_validate "${PROVIDES}" || fail "Provides.oidc_callback must be valid"
pass "valid Provides.oidc_callback"

[[ "$(artifact_provides_has_oidc_callback "${PROVIDES}")" == "1" ]] \
  || fail "has_oidc_callback must be 1"
[[ "$(artifact_provides_oidc_callback "${PROVIDES}")" == "/callback" ]] \
  || fail "oidc_callback reader"
pass "Provides oidc_callback helpers"

# --- valid directories + routes ---
cat >"${PROVIDES}" <<'EOF'
{
  "directories": { ".": ".", "systemd": "./systemd" },
  "routes": { "./path/site.conf": "HTTPS location" }
}
EOF
artifact_provides_validate "${PROVIDES}" || fail "valid Provides must pass"
dirs="$(artifact_provides_directories "${PROVIDES}")"
printf '%s\n' "${dirs}" | grep -Fxq '.' || fail "directories must include ."
printf '%s\n' "${dirs}" | grep -Fxq 'systemd' || fail "directories must include systemd"
[[ "$(artifact_provides_routes "${PROVIDES}")" == "./path/site.conf" ]] \
  || fail "routes must list path"
pass "valid directories + routes"

# --- fail closed: shape ---
printf '[]\n' >"${PROVIDES}"
if artifact_provides_validate "${PROVIDES}" >/dev/null 2>&1; then
  fail "array Provides must fail closed"
fi
cat >"${PROVIDES}" <<'EOF'
{ "directories": { "systemd": false } }
EOF
if artifact_provides_validate "${PROVIDES}" >/dev/null 2>&1; then
  fail "directories false must fail closed"
fi
cat >"${PROVIDES}" <<'EOF'
{ "directories": { "": "x" } }
EOF
if artifact_provides_validate "${PROVIDES}" >/dev/null 2>&1; then
  fail "empty directory key must fail closed"
fi
cat >"${PROVIDES}" <<'EOF'
{ "routes": { "./a.conf": 1 } }
EOF
if artifact_provides_validate "${PROVIDES}" >/dev/null 2>&1; then
  fail "non-string route description must fail closed"
fi
cat >"${PROVIDES}" <<'EOF'
{ "extra": {} }
EOF
if artifact_provides_validate "${PROVIDES}" >/dev/null 2>&1; then
  fail "unknown Provides key must fail closed"
fi
pass "invalid Provides fails closed"

# --- fail closed: Identity keys ---
cat >"${PROVIDES}" <<'EOF'
{ "permissions": [] }
EOF
if artifact_provides_validate "${PROVIDES}" >/dev/null 2>&1; then
  fail "Provides.permissions array must fail closed"
fi

cat >"${PROVIDES}" <<'EOF'
{ "permissions": { "k": "" } }
EOF
if artifact_provides_validate "${PROVIDES}" >/dev/null 2>&1; then
  fail "Provides.permissions empty description must fail closed"
fi

cat >"${PROVIDES}" <<'EOF'
{ "oidc_callback": "" }
EOF
if artifact_provides_validate "${PROVIDES}" >/dev/null 2>&1; then
  fail "Provides.oidc_callback empty string must fail closed"
fi

cat >"${PROVIDES}" <<'EOF'
{ "oidc_callback": "cb" }
EOF
if artifact_provides_validate "${PROVIDES}" >/dev/null 2>&1; then
  fail "Provides.oidc_callback not /… must fail closed"
fi

# Still rejects unknown keys.
cat >"${PROVIDES}" <<'EOF'
{ "extra": {} }
EOF
if artifact_provides_validate "${PROVIDES}" >/dev/null 2>&1; then
  fail "unknown Provides key must fail closed"
fi
pass "Identity-related Provides keys fail/accept as expected"

# --- reserved basenames ---
want=$'binding.json\nmanifest.json\npersist\nprovides.json\nrequires.json'
got="$(artifact_reserved_basenames)"
[[ "${got}" == "${want}" ]] || fail "reserved basenames order/content; got: ${got}"
pass "reserved basenames"

# --- directories key must not be reserved Persist ---
cat >"${PROVIDES}" <<'EOF'
{ "directories": { "persist": "./persist" } }
EOF
if artifact_provides_validate "${PROVIDES}" >/dev/null 2>&1; then
  fail "Provides directories persist must fail closed"
fi
pass "Provides directories cannot target persist"

# --- directories key must not be reserved ---
cat >"${PROVIDES}" <<'EOF'
{ "directories": { "manifest.json": "./manifest.json" } }
EOF
if artifact_provides_validate "${PROVIDES}" >/dev/null 2>&1; then
  fail "directories key reserved basename must fail closed"
fi
pass "directories reserved key fails closed"

# --- destination collision when applying directories ---
DEST="${TMP}/dest"
mkdir -p "${DEST}"
printf '{ "intent": "run", "source": "internal" }\n' >"${DEST}/manifest.json"
cat >"${PROVIDES}" <<'EOF'
{ "directories": { ".": "." } }
EOF
if artifact_provides_reserved_collision "${DEST}" "${PROVIDES}" >/dev/null 2>&1; then
  fail "root directories pull onto dest with reserved files must fail closed"
fi
# targeted pull that does not land on reserved names is OK even if reserved exist
cat >"${PROVIDES}" <<'EOF'
{ "directories": { "systemd": "./systemd" } }
EOF
artifact_provides_reserved_collision "${DEST}" "${PROVIDES}" \
  || fail "non-reserved directory pull must be allowed"
# no reserved at dest + root pull OK
rm -f "${DEST}/manifest.json"
cat >"${PROVIDES}" <<'EOF'
{ "directories": { ".": "." } }
EOF
artifact_provides_reserved_collision "${DEST}" "${PROVIDES}" \
  || fail "root pull with empty dest must be allowed"
pass "reserved destination collision"

cat >"${PROVIDES}" <<'EOF'
{
  "permissions": {
    "demo:api": "API",
    "demo:read": "Read"
  }
}
EOF
[[ "$(artifact_provides_has_permissions "${PROVIDES}")" == "1" ]] || fail "has permissions"
cat >"${PROVIDES}" <<'EOF'
{ "routes": { "/x": "x" } }
EOF
[[ "$(artifact_provides_has_permissions "${PROVIDES}")" == "0" ]] || fail "no permissions"
pass "Provides permissions reader"

echo "All artifact Provides offline tests passed."
