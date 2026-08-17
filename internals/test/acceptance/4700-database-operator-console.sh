#!/usr/bin/env bash
# Acceptance Test: operator ./database.sh read|write console (ADR-0049 / #192).
# SSH TCP tunnel + admin SCRAM; read soft RO seatbelt; write omits it.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
command -v psql >/dev/null || fail "psql not found on operator machine (database.sh requires it)"

# Resolve expected admin role without printing the password.
ADMIN_ENV="$(umask 077; mktemp "${TMPDIR:-/tmp}/platform-db-console-admin.XXXXXX")"
trap 'rm -f "${ADMIN_ENV}"' EXIT
# shellcheck source=../../lib/database/database-admin-credentials.sh
source "${REPO_ROOT}/internals/lib/database/database-admin-credentials.sh"
database_admin_credentials_dotenv_for \
  "${REPO_ROOT}/environments/${ENV_SLUG}" \
  "${ADMIN_ENV}" || fail "Database admin credentials required for console Acceptance"
_line="$(grep -E '^POSTGRES_USER=' "${ADMIN_ENV}" | head -n1)" || true
ADMIN_USER="${_line#POSTGRES_USER=}"
[[ -n "${ADMIN_USER}" ]] || fail "empty POSTGRES_USER from Database admin credentials"
rm -f "${ADMIN_ENV}"
trap - EXIT

run_console_sql() {
  local mode="$1"
  local sql="$2"
  # Stdin feeds psql non-interactively through database.sh.
  printf '%s\n' "${sql}" | "${REPO_ROOT}/database.sh" "${mode}" --env "${ENV_SLUG}" 2>/dev/null
}

# Default / read: connect as admin; soft default_transaction_read_only=on.
out="$(run_console_sql read "SELECT current_user || '|' || current_setting('default_transaction_read_only');")" \
  || fail "database.sh read failed to run SQL"
printf '%s\n' "${out}" | grep -Fq "${ADMIN_USER}|on" \
  || fail "read want '${ADMIN_USER}|on', got: ${out}"
pass "database.sh read connects as admin with soft RO"

# Omitted mode defaults to read (same soft RO).
out="$(printf '%s\n' "SHOW default_transaction_read_only;" \
  | "${REPO_ROOT}/database.sh" --env "${ENV_SLUG}" 2>/dev/null)" \
  || fail "database.sh (default mode) failed"
printf '%s\n' "${out}" | grep -Eq '^[[:space:]]*on[[:space:]]*$' \
  || fail "default mode should be soft RO, got: ${out}"
pass "database.sh default mode is read (soft RO)"

# write: admin connect without soft RO session default.
out="$(run_console_sql write "SELECT current_user || '|' || current_setting('default_transaction_read_only');")" \
  || fail "database.sh write failed to run SQL"
printf '%s\n' "${out}" | grep -Fq "${ADMIN_USER}|off" \
  || fail "write want '${ADMIN_USER}|off', got: ${out}"
pass "database.sh write connects as admin without soft RO"
