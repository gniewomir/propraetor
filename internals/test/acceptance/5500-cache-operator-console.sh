#!/usr/bin/env bash
# Acceptance Test: operator ./cache.sh admin console (ADR-0055 / #226).
# SSH TCP tunnel + admin client cert + ROOT_CACHE_* password; PING + ACL WHOAMI.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
command -v valkey-cli >/dev/null \
  || fail "valkey-cli not found on operator machine (cache.sh requires it)"

# Resolve expected admin username without printing the password.
ADMIN_ENV="$(umask 077; mktemp "${TMPDIR:-/tmp}/platform-cache-console-admin.XXXXXX")"
trap 'rm -f "${ADMIN_ENV}"' EXIT
# shellcheck source=../../lib/cache/cache-admin-credentials.sh
source "${REPO_ROOT}/internals/lib/cache/cache-admin-credentials.sh"
cache_admin_credentials_dotenv_for \
  "${REPO_ROOT}/environments/${ENV_SLUG}" \
  "${ADMIN_ENV}" || fail "Cache admin credentials required for console Acceptance"
_line="$(grep -E '^CACHE_ADMIN_USER=' "${ADMIN_ENV}" | head -n1)" || true
ADMIN_USER="${_line#CACHE_ADMIN_USER=}"
[[ -n "${ADMIN_USER}" ]] || fail "empty CACHE_ADMIN_USER from Cache admin credentials"
rm -f "${ADMIN_ENV}"
trap - EXIT

run_console() {
  # Extra args forward to valkey-cli non-interactively through cache.sh.
  "${REPO_ROOT}/cache.sh" --env "${ENV_SLUG}" -- "$@" 2>/dev/null
}

# PING as admin over the operator tunnel.
out="$(run_console PING)" || fail "cache.sh PING failed"
printf '%s\n' "${out}" | grep -qx PONG \
  || fail "PING want PONG, got: ${out}"
pass "cache.sh PING returns PONG as admin"

# ACL visibility: authenticated identity is the Cache admin username.
out="$(run_console ACL WHOAMI)" || fail "cache.sh ACL WHOAMI failed"
printf '%s\n' "${out}" | grep -Fxq "${ADMIN_USER}" \
  || fail "ACL WHOAMI want '${ADMIN_USER}', got: ${out}"
pass "cache.sh ACL WHOAMI is Cache admin user"
