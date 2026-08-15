#!/usr/bin/env bash
# Offline contract: Database Setup mount chown + standing vs Declaration converge
# ordering (#232 / ADR-0049 / #188).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SETUP="${REPO_ROOT}/internals/host-scripts/lib/database-setup-host.sh"
AUTH="${REPO_ROOT}/internals/host-scripts/lib/database-auth-conf-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -f "${SETUP}" ]] || fail "missing ${SETUP}"
[[ -f "${AUTH}" ]] || fail "missing ${AUTH}"

# Mount-point chown (non-recursive) — required for cold root:root pgdata.
grep -Eq 'chown[[:space:]]+"\$\{USER_NAME\}:\$\{USER_NAME\}"[[:space:]]+"\$\{PGDATA_DIR\}"' "${SETUP}" \
  || fail "database_standing_ensure must chown PGDATA_DIR to Platform User before :U start"

# Must not recurse into a live cluster from Host Setup.
if grep -Eq 'chown[[:space:]]+-R[[:space:]]+"\$\{USER_NAME\}:\$\{USER_NAME\}"[[:space:]]+"\$\{PGDATA_DIR\}"' "${SETUP}"; then
  fail "database_standing_ensure must not chown -R PGDATA_DIR (live subuid cluster / PANIC risk)"
fi

# Ready-wait must fail closed when the unit is failed (not only after pg_isready timeout).
grep -Fq 'ActiveState' "${SETUP}" \
  || fail "database_wait_ready must observe database-postgres ActiveState"
grep -Fq 'database-postgres.service failed before ready' "${SETUP}" \
  || fail "database_wait_ready must fail closed on ActiveState=failed"

# Named seams (#232).
grep -Eq '^database_standing_ensure\(\)' "${SETUP}" \
  || fail "standing ensure must be named database_standing_ensure"
grep -Eq '^database_fulfill_declarations\(\)' \
  "${REPO_ROOT}/internals/host-scripts/lib/database-fulfill-host.sh" \
  || fail "Declaration converge adapter must be named database_fulfill_declarations"
grep -Fq 'if [[ ! -f "${ident}" ]]; then' "${AUTH}" \
  || fail "standing auth must create-if-missing pg_ident (not idle-empty rewrite)"

# Ordering invariant.
pre_body="$(awk '/^database_setup_pre_workloads\(\)/,/^}/' "${SETUP}")"
printf '%s\n' "${pre_body}" | grep -Fq 'database_standing_ensure' \
  || fail "pre-workloads must call database_standing_ensure"
printf '%s\n' "${pre_body}" | grep -Fq 'database_fulfill_declarations' \
  || fail "pre-workloads must call Declaration converge"
standing_line="$(printf '%s\n' "${pre_body}" | grep -n 'database_standing_ensure' | head -n1 | cut -d: -f1)"
fulfill_line="$(printf '%s\n' "${pre_body}" | grep -n 'database_fulfill_declarations' | head -n1 | cut -d: -f1)"
[[ "${standing_line}" -lt "${fulfill_line}" ]] \
  || fail "pre-workloads must standing ensure before Declaration converge"

post_body="$(awk '/^database_setup_post_workloads\(\)/,/^}/' "${SETUP}")"
printf '%s\n' "${post_body}" | grep -Fq 'database_standing_ensure' \
  || fail "post-workloads must call database_standing_ensure"
printf '%s\n' "${post_body}" | grep -Fq 'database_drop_absent_fulfillments' \
  || fail "post-workloads must drop Orphan-absent fulfillments"
if printf '%s\n' "${post_body}" | grep -Fq 'database_fulfill_declarations'; then
  fail "post-workloads must not re-fulfill after standing ensure"
fi
standing_post="$(printf '%s\n' "${post_body}" | grep -n 'database_standing_ensure' | head -n1 | cut -d: -f1)"
drop_post="$(printf '%s\n' "${post_body}" | grep -n 'database_drop_absent_fulfillments' | head -n1 | cut -d: -f1)"
[[ "${standing_post}" -lt "${drop_post}" ]] \
  || fail "post-workloads must standing ensure before Orphan drop"

pass "Database standing vs Declaration converge ordering"

echo "All database-setup-host offline tests passed."
