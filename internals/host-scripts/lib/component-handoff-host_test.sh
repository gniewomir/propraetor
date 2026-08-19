#!/usr/bin/env bash
# Unit tests: Component Setup handoff paths + install (Host Volume contract).
# Seam: component_handoff_* under ambient HV_ROOT.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=component-handoff-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/component-handoff-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/component-handoff.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export HV_ROOT="${TMP}/host-volume"

# --- path helpers resolve under HV_ROOT/components/handoff ---
root="$(component_handoff_root)"
[[ "${root}" == "${HV_ROOT}/components/handoff" ]] \
  || fail "handoff root wrong: ${root}"
[[ "$(component_handoff_acme_want_list)" == "${root}/acme-want-list" ]] \
  || fail "acme want-list path wrong"
[[ "$(component_handoff_acme_env)" == "${root}/acme.env" ]] \
  || fail "acme env path wrong"
[[ "$(component_handoff_database_admin_env)" == "${root}/database-admin.env" ]] \
  || fail "database admin path wrong"
[[ "$(component_handoff_cache_admin_env)" == "${root}/cache-admin.env" ]] \
  || fail "cache admin path wrong"
[[ "$(component_handoff_identity_config)" == "${root}/identity.json" ]] \
  || fail "identity config path wrong"
[[ "$(component_handoff_identity_admin_env)" == "${root}/identity-admin.env" ]] \
  || fail "identity admin path wrong"
[[ "$(component_handoff_environment_slug_file)" == "${root}/environment-slug" ]] \
  || fail "environment slug path wrong"
pass "path helpers resolve under Host Volume handoff root"

# --- require ACME fails closed when missing ---
if component_handoff_require_acme 2>"${TMP}/err-require"; then
  fail "require_acme must fail when handoff files missing"
fi
grep -Eqi 'ACME|want-list|handoff' "${TMP}/err-require" \
  || fail "require_acme rejection unclear: $(cat "${TMP}/err-require")"
pass "require_acme fails closed when missing"

# --- install ACME from stage files ---
STAGE="${TMP}/stage"
mkdir -p "${STAGE}"
printf '%s\n' 'alpha.example.test' >"${STAGE}/want"
printf '%s\n' 'EDGE_ACME_DIRECTORY=staging' >"${STAGE}/acme.env"
component_handoff_install_acme "${STAGE}/want" "${STAGE}/acme.env" \
  || fail "install_acme failed"
[[ -f "$(component_handoff_acme_want_list)" ]] || fail "want-list not installed"
[[ -f "$(component_handoff_acme_env)" ]] || fail "acme.env not installed"
grep -Fxq 'alpha.example.test' "$(component_handoff_acme_want_list)" \
  || fail "want-list content wrong"
grep -Fxq 'EDGE_ACME_DIRECTORY=staging' "$(component_handoff_acme_env)" \
  || fail "acme.env content wrong"
component_handoff_require_acme || fail "require_acme should pass after install"
pass "install_acme writes handoff files require_acme accepts"

# --- install ACME fails closed on missing stage ---
if component_handoff_install_acme "${STAGE}/missing" "${STAGE}/acme.env" \
  2>"${TMP}/err-want"; then
  fail "install_acme must fail on missing want-list stage"
fi
if component_handoff_install_acme "${STAGE}/want" "${STAGE}/missing.env" \
  2>"${TMP}/err-env"; then
  fail "install_acme must fail on missing ACME env stage"
fi
pass "install_acme fails closed on missing stage"

# --- install Database admin ---
printf '%s\n' 'POSTGRES_USER=dbadmin' 'POSTGRES_PASSWORD=secret' \
  >"${STAGE}/db-admin.env"
component_handoff_install_database_admin "${STAGE}/db-admin.env" \
  || fail "install_database_admin failed"
[[ -f "$(component_handoff_database_admin_env)" ]] || fail "db admin not installed"
grep -Fq 'POSTGRES_USER=dbadmin' "$(component_handoff_database_admin_env)" \
  || fail "db admin content wrong"
# mode 0600 when install(1) available
mode="$(stat -f %Lp "$(component_handoff_database_admin_env)" 2>/dev/null \
  || stat -c %a "$(component_handoff_database_admin_env)")"
[[ "${mode}" == "600" ]] || fail "db admin mode want 600, got ${mode}"
pass "install_database_admin writes 0600 EnvironmentFile"

# --- install Database admin fails closed on missing stage ---
if component_handoff_install_database_admin "${STAGE}/missing-db.env" \
  2>"${TMP}/err-db"; then
  fail "install_database_admin must fail on missing stage"
fi
grep -Eqi 'Database admin|missing' "${TMP}/err-db" \
  || fail "db admin rejection unclear: $(cat "${TMP}/err-db")"
pass "install_database_admin fails closed on missing stage"

# --- install Cache admin ---
printf '%s\n' 'CACHE_ADMIN_USER=cacheadmin' 'CACHE_ADMIN_PASSWORD=secret' \
  >"${STAGE}/cache-admin.env"
component_handoff_install_cache_admin "${STAGE}/cache-admin.env" \
  || fail "install_cache_admin failed"
[[ -f "$(component_handoff_cache_admin_env)" ]] || fail "cache admin not installed"
grep -Fq 'CACHE_ADMIN_USER=cacheadmin' "$(component_handoff_cache_admin_env)" \
  || fail "cache admin content wrong"
mode="$(stat -f %Lp "$(component_handoff_cache_admin_env)" 2>/dev/null \
  || stat -c %a "$(component_handoff_cache_admin_env)")"
[[ "${mode}" == "600" ]] || fail "cache admin mode want 600, got ${mode}"
pass "install_cache_admin writes 0600 EnvironmentFile"

# --- install Cache admin fails closed on missing stage ---
if component_handoff_install_cache_admin "${STAGE}/missing-cache.env" \
  2>"${TMP}/err-cache"; then
  fail "install_cache_admin must fail on missing stage"
fi
grep -Eqi 'Cache admin|missing' "${TMP}/err-cache" \
  || fail "cache admin rejection unclear: $(cat "${TMP}/err-cache")"
pass "install_cache_admin fails closed on missing stage"

# --- install Identity config + admin ---
printf '%s\n' '{"fqdn":"auth.example.test"}' >"${STAGE}/identity.json"
printf '%s\n' \
  'STATIC_API_KEY=0123456789abcdef' \
  'ENCRYPTION_KEY=enckey' \
  'IDENTITY_ADMIN_EMAIL=ops@example.com' \
  'APP_URL=https://auth.example.test' \
  >"${STAGE}/identity-admin.env"
component_handoff_install_identity "${STAGE}/identity.json" "${STAGE}/identity-admin.env" \
  || fail "install_identity failed"
[[ -f "$(component_handoff_identity_config)" ]] || fail "identity.json not installed"
[[ -f "$(component_handoff_identity_admin_env)" ]] || fail "identity admin not installed"
grep -Fq 'auth.example.test' "$(component_handoff_identity_config)" \
  || fail "identity.json content wrong"
grep -Fq 'STATIC_API_KEY=0123456789abcdef' "$(component_handoff_identity_admin_env)" \
  || fail "identity admin content wrong"
printf 'test\n' >"${STAGE}/environment-slug"
component_handoff_install_environment_slug "${STAGE}/environment-slug" \
  || fail "install_environment_slug failed"
component_handoff_require_identity || fail "require_identity should pass after install"
pass "install_identity + environment slug handoff require_identity accepts"

[[ "$(component_handoff_environment_slug)" == "test" ]] \
  || fail "environment slug readback"
pass "install_environment_slug writes handoff slug"

if component_handoff_install_identity "${STAGE}/missing.json" "${STAGE}/identity-admin.env" \
  2>"${TMP}/err-id-config"; then
  fail "install_identity must fail on missing identity.json stage"
fi
if component_handoff_install_identity "${STAGE}/identity.json" "${STAGE}/missing-admin.env" \
  2>"${TMP}/err-id-admin"; then
  fail "install_identity must fail on missing admin stage"
fi
pass "install_identity fails closed on missing stage"

# --- no /tmp/platform-* in this module ---
if grep -E '/tmp/platform-' \
  "${REPO_ROOT}/internals/host-scripts/lib/component-handoff-host.sh"; then
  fail "handoff module must not use /tmp/platform-* paths"
fi
pass "handoff module owns Host Volume paths only"

echo "All component-handoff-host offline tests passed."
