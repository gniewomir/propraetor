#!/usr/bin/env bash
# Unit tests: Binding parse + full-fulfill + environment remap (ADR-0053 / #199 / #201).
# Seam: artifact_binding_validate / artifact_binding_fulfill /
# artifact_binding_environment_remap / artifact_binding_environment_select.
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
  "directories": { "systemd": "./systemd" },
  "routes": {
    "./path/site.conf": "main",
    "./path/extra.conf": "extra"
  }
}
EOF
cat >"${REQUIRES}" <<'EOF'
{
  "environment": { "API_KEY": "key", "APP_URL": "url" },
  "database": false,
  "cache": false
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
{ "directories": { "systemd": "./systemd" } }
EOF
cat >"${REQUIRES}" <<'EOF'
{ "environment": {}, "database": true, "cache": false }
EOF
cat >"${BINDING}" <<'EOF'
{ "domains": {}, "environment": {} }
EOF
artifact_binding_fulfill "${BINDING}" "${PROVIDES}" "${REQUIRES}" "${WANTLIST}" \
  || fail "zero routes + empty Requires env must fulfill"
pass "zero routes fulfill"

# --- environment remap: bag key → Requires name (ADR-0053 / #201) ---
cat >"${PROVIDES}" <<'EOF'
{ "directories": { "systemd": "./systemd" } }
EOF
cat >"${REQUIRES}" <<'EOF'
{
  "environment": { "API_KEY": "key", "APP_URL": "url" },
  "database": false,
  "cache": false
}
EOF
cat >"${BINDING}" <<'EOF'
{
  "environment": {
    "SECRET_BAG": "API_KEY",
    "PUBLIC_URL": "APP_URL"
  }
}
EOF
got="$(artifact_binding_environment_remap "${BINDING}" "${REQUIRES}")" \
  || fail "env remap happy path must pass"
# Stable order: Requires environment names sorted.
[[ "${got}" == $'SECRET_BAG=API_KEY\nPUBLIC_URL=APP_URL' ]] \
  || fail "expected BAG=Requires pairs in Requires-name order, got: ${got}"
pass "environment remap prints bag=Requires pairs"

cat >"${REQUIRES}" <<'EOF'
{ "environment": {}, "database": false, "cache": false }
EOF
cat >"${BINDING}" <<'EOF'
{ "environment": {} }
EOF
got="$(artifact_binding_environment_remap "${BINDING}" "${REQUIRES}")" \
  || fail "empty Requires environment must remap"
[[ -z "${got}" ]] || fail "empty Requires environment should print no pairs"
pass "empty Requires environment remaps to no pairs"

cat >"${REQUIRES}" <<'EOF'
{ "environment": { "API_KEY": "key" }, "database": false, "cache": false }
EOF
cat >"${BINDING}" <<'EOF'
{ "environment": {} }
EOF
if artifact_binding_environment_remap "${BINDING}" "${REQUIRES}" >/dev/null 2>&1; then
  fail "missing Requires remap RHS must fail closed"
fi
pass "incomplete environment remap fails closed"

# --- Binding-only environment select (zip Setup; full-fulfill on Host) ---
cat >"${BINDING}" <<'EOF'
{
  "environment": {
    "SECRET_BAG": "API_KEY",
    "PUBLIC_URL": "APP_URL"
  }
}
EOF
got="$(artifact_binding_environment_select "${BINDING}")" \
  || fail "Binding-only select happy path must pass"
[[ "${got}" == $'SECRET_BAG=API_KEY\nPUBLIC_URL=APP_URL' ]] \
  || fail "expected BAG=Requires pairs in Requires-name order, got: ${got}"
pass "environment select prints bag=Requires pairs without Requires"

cat >"${BINDING}" <<'EOF'
{ "environment": {} }
EOF
got="$(artifact_binding_environment_select "${BINDING}")" \
  || fail "empty Binding.environment must select"
[[ -z "${got}" ]] || fail "empty Binding.environment should print no pairs"
pass "empty Binding.environment selects to no pairs"

cat >"${BINDING}" <<'EOF'
{ "environment": { "BAG_A": "API_KEY", "BAG_B": "API_KEY" } }
EOF
if artifact_binding_environment_select "${BINDING}" >/dev/null 2>&1; then
  fail "duplicate Binding remap RHS must fail closed"
fi
pass "duplicate environment select RHS fails closed"

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
