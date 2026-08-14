#!/usr/bin/env bash
# Unit tests: Binding parse + full-fulfill (ADR-0053 / #199).
# Seam: artifact_binding_validate / artifact_binding_fulfill.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=binding.sh
source "${REPO_ROOT}/internals/lib/artifact/binding.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/artifact-binding.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
BINDING="${TMP}/binding.json"
PROVIDES="${TMP}/provides.json"
REQUIRES="${TMP}/requires.json"
WANTLIST="${TMP}/wantlist.txt"

# --- valid empty-ish Binding ---
printf '{}\n' >"${BINDING}"
artifact_binding_validate "${BINDING}" || fail "empty Binding must be valid"
pass "empty Binding"

# --- valid shape ---
cat >"${BINDING}" <<'EOF'
{
  "domains": { "app.example.com": ["./path/site.conf"] },
  "environment": { "BAG_KEY": "API_KEY" }
}
EOF
artifact_binding_validate "${BINDING}" || fail "valid Binding must pass"
pass "valid Binding shape"

# --- fail closed shape ---
cat >"${BINDING}" <<'EOF'
{ "domains": { "app.example.com": "./path/site.conf" } }
EOF
if artifact_binding_validate "${BINDING}" >/dev/null 2>&1; then
  fail "domains value must be an array"
fi
cat >"${BINDING}" <<'EOF'
{ "domains": { "app.example.com": [""] } }
EOF
if artifact_binding_validate "${BINDING}" >/dev/null 2>&1; then
  fail "empty route path in domains must fail closed"
fi
cat >"${BINDING}" <<'EOF'
{ "environment": { "BAG": 1 } }
EOF
if artifact_binding_validate "${BINDING}" >/dev/null 2>&1; then
  fail "non-string environment remap must fail closed"
fi
cat >"${BINDING}" <<'EOF'
{ "extra": {} }
EOF
if artifact_binding_validate "${BINDING}" >/dev/null 2>&1; then
  fail "unknown Binding key must fail closed"
fi
pass "invalid Binding fails closed"

# --- full fulfill: happy path ---
cat >"${PROVIDES}" <<'EOF'
{
  "directories": { "quadlets": "./quadlets" },
  "routes": {
    "./path/site.conf": "main",
    "./path/extra.conf": "extra"
  }
}
EOF
cat >"${REQUIRES}" <<'EOF'
{
  "environment": { "API_KEY": "key", "APP_URL": "url" },
  "database": false
}
EOF
cat >"${BINDING}" <<'EOF'
{
  "domains": {
    "app.example.com": ["./path/site.conf", "./path/extra.conf"],
    "www.example.com": ["./path/site.conf"]
  },
  "environment": {
    "SECRET_BAG": "API_KEY",
    "PUBLIC_URL": "APP_URL"
  }
}
EOF
printf '%s\n' 'app.example.com' 'www.example.com' 'other.example.com' >"${WANTLIST}"
artifact_binding_fulfill "${BINDING}" "${PROVIDES}" "${REQUIRES}" "${WANTLIST}" \
  || fail "full fulfill happy path must pass"
# want-list optional: omit ⇒ skip FQDN ⊆ check
artifact_binding_fulfill "${BINDING}" "${PROVIDES}" "${REQUIRES}" \
  || fail "fulfill without want-list must pass when otherwise complete"
pass "full fulfill happy path"

# --- every Provides route in ≥1 FQDN array ---
cat >"${BINDING}" <<'EOF'
{
  "domains": { "app.example.com": ["./path/site.conf"] },
  "environment": { "SECRET_BAG": "API_KEY", "PUBLIC_URL": "APP_URL" }
}
EOF
if artifact_binding_fulfill "${BINDING}" "${PROVIDES}" "${REQUIRES}" >/dev/null 2>&1; then
  fail "unbound Provides route must fail closed"
fi
pass "unbound Provides route fails closed"

# --- every Requires env name exactly one remap RHS ---
cat >"${BINDING}" <<'EOF'
{
  "domains": {
    "app.example.com": ["./path/site.conf", "./path/extra.conf"]
  },
  "environment": { "SECRET_BAG": "API_KEY" }
}
EOF
if artifact_binding_fulfill "${BINDING}" "${PROVIDES}" "${REQUIRES}" >/dev/null 2>&1; then
  fail "missing Requires remap must fail closed"
fi
cat >"${BINDING}" <<'EOF'
{
  "domains": {
    "app.example.com": ["./path/site.conf", "./path/extra.conf"]
  },
  "environment": {
    "SECRET_BAG": "API_KEY",
    "PUBLIC_URL": "APP_URL",
    "OTHER": "API_KEY"
  }
}
EOF
if artifact_binding_fulfill "${BINDING}" "${PROVIDES}" "${REQUIRES}" >/dev/null 2>&1; then
  fail "duplicate Requires remap RHS must fail closed"
fi
cat >"${BINDING}" <<'EOF'
{
  "domains": {
    "app.example.com": ["./path/site.conf", "./path/extra.conf"]
  },
  "environment": {
    "SECRET_BAG": "API_KEY",
    "PUBLIC_URL": "APP_URL",
    "EXTRA": "UNKNOWN"
  }
}
EOF
if artifact_binding_fulfill "${BINDING}" "${PROVIDES}" "${REQUIRES}" >/dev/null 2>&1; then
  fail "remap to unknown Requires name must fail closed"
fi
pass "Requires remap full-fulfill fails closed"

# --- Binding route path must exist in Provides ---
cat >"${BINDING}" <<'EOF'
{
  "domains": {
    "app.example.com": ["./path/site.conf", "./path/extra.conf", "./missing.conf"]
  },
  "environment": { "SECRET_BAG": "API_KEY", "PUBLIC_URL": "APP_URL" }
}
EOF
if artifact_binding_fulfill "${BINDING}" "${PROVIDES}" "${REQUIRES}" >/dev/null 2>&1; then
  fail "Binding route absent from Provides must fail closed"
fi
pass "unknown Binding route fails closed"

# --- FQDNs ⊆ want-list when supplied ---
cat >"${BINDING}" <<'EOF'
{
  "domains": {
    "app.example.com": ["./path/site.conf", "./path/extra.conf"],
    "evil.example.com": ["./path/site.conf"]
  },
  "environment": { "SECRET_BAG": "API_KEY", "PUBLIC_URL": "APP_URL" }
}
EOF
printf '%s\n' 'app.example.com' 'www.example.com' >"${WANTLIST}"
if artifact_binding_fulfill "${BINDING}" "${PROVIDES}" "${REQUIRES}" "${WANTLIST}" \
  >/dev/null 2>&1; then
  fail "FQDN outside want-list must fail closed"
fi
pass "want-list FQDN subset fails closed"

# --- zero Provides routes is valid ---
cat >"${PROVIDES}" <<'EOF'
{ "directories": { "quadlets": "./quadlets" } }
EOF
cat >"${REQUIRES}" <<'EOF'
{ "environment": {}, "database": true }
EOF
cat >"${BINDING}" <<'EOF'
{ "domains": {}, "environment": {} }
EOF
artifact_binding_fulfill "${BINDING}" "${PROVIDES}" "${REQUIRES}" "${WANTLIST}" \
  || fail "zero routes + empty Requires env must fulfill"
pass "zero routes fulfill"

# --- no FQDN-as-filename Route SoT dual-read in contract libs ---
if grep -E 'routes/\$\{|basename.*\.conf|/\$\{fqdn\}' \
    "${REPO_ROOT}/internals/lib/artifact/source.sh" \
    "${REPO_ROOT}/internals/lib/artifact/provides.sh" \
    "${REPO_ROOT}/internals/lib/artifact/requires.sh" \
    "${REPO_ROOT}/internals/lib/artifact/binding.sh"; then
  fail "Artifact contract libs must not dual-read FQDN-as-filename Route SoT"
fi
pass "no FQDN-as-filename Route SoT dual-read"

echo "All artifact Binding offline tests passed."
