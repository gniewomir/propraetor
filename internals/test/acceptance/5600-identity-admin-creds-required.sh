#!/usr/bin/env bash
# Acceptance Test: missing Identity admin credentials fail ensure-components closed (ADR-0057 / #251).
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

if [[ -f "${ENV_FILE}" ]]; then
  BACKUP="$(mktemp "${TMPDIR:-/tmp}/platform-root-identity-env.XXXXXX")"
  mv "${ENV_FILE}" "${BACKUP}"
fi
if [[ -f "${ENV_OVERRIDE}" ]]; then
  BACKUP_OVERRIDE="$(mktemp "${TMPDIR:-/tmp}/platform-root-identity-override.XXXXXX")"
  mv "${ENV_OVERRIDE}" "${BACKUP_OVERRIDE}"
fi

err="$(mktemp "${TMPDIR:-/tmp}/platform-root-identity-missing.XXXXXX")"
if env -u ROOT_IDENTITY_API_KEY -u ROOT_IDENTITY_ENCRYPTION_KEY -u ROOT_IDENTITY_ADMIN_EMAIL \
  ROOT_DB_USER=acceptance-db ROOT_DB_PASSWORD=acceptance-db \
  ROOT_CACHE_USER=acceptance-cache ROOT_CACHE_PASSWORD=acceptance-cache \
  "${REPO_ROOT}/internals/ensure-components.sh" pre-workloads --env "${ENV_SLUG}" \
  >/dev/null 2>"${err}"; then
  rm -f "${err}"
  fail "missing ROOT_IDENTITY_* must fail ensure-components closed"
fi
grep -Eqi 'ROOT_IDENTITY_|Identity admin|fail closed|missing' "${err}" \
  || fail "missing Identity admin credentials rejection unclear: $(cat "${err}")"
rm -f "${err}"
pass "missing Identity admin credentials fail ensure-components closed"

restore_env
BACKUP=""
BACKUP_OVERRIDE=""
trap - EXIT
