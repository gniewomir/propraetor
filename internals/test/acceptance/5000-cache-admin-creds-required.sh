#!/usr/bin/env bash
# Acceptance Test: missing Cache admin credentials fail Cache Setup closed (ADR-0055 / #221).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
ENV_DIR="${REPO_ROOT}/environments/${ENV_SLUG}"
ENV_FILE="${ENV_DIR}/.env"
ENV_OVERRIDE="${ENV_DIR}/.env.override"
BACKUP=""
BACKUP_OVERRIDE=""

restore_env() {
  if [[ -n "${BACKUP}" && -f "${BACKUP}" ]]; then
    mv "${BACKUP}" "${ENV_FILE}"
  fi
  if [[ -n "${BACKUP_OVERRIDE}" && -f "${BACKUP_OVERRIDE}" ]]; then
    mv "${BACKUP_OVERRIDE}" "${ENV_OVERRIDE}"
  fi
}
trap restore_env EXIT

# Hide Environment dotenv bag so resolve cannot see ROOT_CACHE_* (do not print secrets).
if [[ -f "${ENV_FILE}" ]]; then
  BACKUP="$(mktemp "${TMPDIR:-/tmp}/platform-root-cache-env.XXXXXX")"
  mv "${ENV_FILE}" "${BACKUP}"
fi
if [[ -f "${ENV_OVERRIDE}" ]]; then
  BACKUP_OVERRIDE="$(mktemp "${TMPDIR:-/tmp}/platform-root-cache-override.XXXXXX")"
  mv "${ENV_OVERRIDE}" "${BACKUP_OVERRIDE}"
fi

err="$(mktemp "${TMPDIR:-/tmp}/platform-root-cache-missing.XXXXXX")"
# Supply Database admin via shell so failure is specifically missing Cache admin.
if env -u ROOT_CACHE_USER -u ROOT_CACHE_PASSWORD \
  ROOT_DB_USER=acceptance-db ROOT_DB_PASSWORD=acceptance-db \
  "${REPO_ROOT}/internals/ensure-components.sh" pre-workloads --env "${ENV_SLUG}" \
  >/dev/null 2>"${err}"; then
  rm -f "${err}"
  fail "missing ROOT_CACHE_USER/ROOT_CACHE_PASSWORD must fail Cache Setup closed"
fi
grep -Eqi 'ROOT_CACHE_USER|ROOT_CACHE_PASSWORD|Cache admin|fail closed|missing' "${err}" \
  || fail "missing Cache admin credentials rejection unclear: $(cat "${err}")"
rm -f "${err}"
pass "missing Cache admin credentials fail ensure-components closed"

# Restore before suite baseline Deploy on the next case.
restore_env
BACKUP=""
BACKUP_OVERRIDE=""
trap - EXIT
