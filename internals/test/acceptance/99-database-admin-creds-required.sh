#!/usr/bin/env bash
# Acceptance Test: missing Database admin credentials fail Database Setup closed (ADR-0049 / #188).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
ENV_DIR="${REPO_ROOT}/environments/${ENV_SLUG}"
ENV_FILE="${ENV_DIR}/.env"
BACKUP=""

restore_env() {
  if [[ -n "${BACKUP}" && -f "${BACKUP}" ]]; then
    mv "${BACKUP}" "${ENV_FILE}"
  fi
}
trap restore_env EXIT

# Hide Environment dotenv so resolve cannot see ROOT_DB_* (do not print secrets).
if [[ -f "${ENV_FILE}" ]]; then
  BACKUP="$(mktemp "${TMPDIR:-/tmp}/platform-root-db-env.XXXXXX")"
  mv "${ENV_FILE}" "${BACKUP}"
fi

err="$(mktemp "${TMPDIR:-/tmp}/platform-root-db-missing.XXXXXX")"
if env -u ROOT_DB_USER -u ROOT_DB_PASSWORD \
  "${REPO_ROOT}/internals/ensure-components.sh" pre-workloads --env "${ENV_SLUG}" \
  >/dev/null 2>"${err}"; then
  rm -f "${err}"
  fail "missing ROOT_DB_USER/ROOT_DB_PASSWORD must fail Database Setup closed"
fi
grep -Eqi 'ROOT_DB_USER|ROOT_DB_PASSWORD|Database admin|fail closed|missing' "${err}" \
  || fail "missing admin credentials rejection unclear: $(cat "${err}")"
rm -f "${err}"
pass "missing Database admin credentials fail ensure-components closed"

# Restore before suite baseline Deploy on the next case.
restore_env
BACKUP=""
trap - EXIT
