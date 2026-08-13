#!/usr/bin/env bash
# Offline contract: Database Setup must Platform-own the pgdata bind-mount root
# before rootless :U start (fresh root-owned mkdir → lchown EPERM otherwise).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SETUP="${REPO_ROOT}/internals/host-scripts/lib/database-setup-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "${SETUP}" ]] || fail "missing ${SETUP}"

# Mount-point chown (non-recursive) — required for cold root:root pgdata.
grep -Eq 'chown[[:space:]]+"\$\{USER_NAME\}:\$\{USER_NAME\}"[[:space:]]+"\$\{PGDATA_DIR\}"' "${SETUP}" \
  || fail "database_setup must chown PGDATA_DIR to Platform User before :U start"

# Must not recurse into a live cluster from Host Setup.
if grep -Eq 'chown[[:space:]]+-R[[:space:]]+"\$\{USER_NAME\}:\$\{USER_NAME\}"[[:space:]]+"\$\{PGDATA_DIR\}"' "${SETUP}"; then
  fail "database_setup must not chown -R PGDATA_DIR (live subuid cluster / PANIC risk)"
fi

# Ready-wait must fail closed when the unit is failed (not only after pg_isready timeout).
grep -Fq 'ActiveState' "${SETUP}" \
  || fail "database_wait_ready must observe database-postgres ActiveState"
grep -Fq 'database-postgres.service failed before ready' "${SETUP}" \
  || fail "database_wait_ready must fail closed on ActiveState=failed"

echo "All database-setup-host offline tests passed."
