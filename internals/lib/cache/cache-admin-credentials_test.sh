#!/usr/bin/env bash
# Unit tests: Cache admin credentials resolve (ADR-0055 / #221).
# Offline: temp Environment dir + shell overrides. No Host / SSH.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=cache-admin-credentials.sh
source "${REPO_ROOT}/internals/lib/cache/cache-admin-credentials.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/cache-admin-creds.XXXXXX")"
trap 'rm -rf "${TMP}"; unset ROOT_CACHE_USER ROOT_CACHE_PASSWORD || true' EXIT
ENV_DIR="${TMP}/env"
mkdir -p "${ENV_DIR}"
OUT="${TMP}/out.env"

unset ROOT_CACHE_USER ROOT_CACHE_PASSWORD || true

# --- missing both keys fails closed ---
: >"${ENV_DIR}/.env"
if cache_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" 2>"${TMP}/err-missing"; then
  fail "missing ROOT_CACHE_* must fail closed"
fi
grep -Eqi 'ROOT_CACHE_USER|ROOT_CACHE_PASSWORD|fail closed|missing' "${TMP}/err-missing" \
  || fail "missing-keys rejection unclear: $(cat "${TMP}/err-missing")"
[[ ! -e "${OUT}" ]] || fail "outfile must not exist after missing-keys failure"
pass "missing both Cache admin credentials fails closed"

# --- missing password fails closed ---
printf 'ROOT_CACHE_USER=cacheadmin\n' >"${ENV_DIR}/.env"
if cache_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" 2>"${TMP}/err-pw"; then
  fail "missing ROOT_CACHE_PASSWORD must fail closed"
fi
grep -Eqi 'ROOT_CACHE_PASSWORD' "${TMP}/err-pw" \
  || fail "missing-password rejection unclear: $(cat "${TMP}/err-pw")"
pass "missing ROOT_CACHE_PASSWORD fails closed"

# --- missing user fails closed ---
printf 'ROOT_CACHE_PASSWORD=secret\n' >"${ENV_DIR}/.env"
if cache_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" 2>"${TMP}/err-user"; then
  fail "missing ROOT_CACHE_USER must fail closed"
fi
grep -Eqi 'ROOT_CACHE_USER' "${TMP}/err-user" \
  || fail "missing-user rejection unclear: $(cat "${TMP}/err-user")"
pass "missing ROOT_CACHE_USER fails closed"

# --- empty values fail closed ---
printf 'ROOT_CACHE_USER=\nROOT_CACHE_PASSWORD=secret\n' >"${ENV_DIR}/.env"
if cache_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" 2>"${TMP}/err-empty"; then
  fail "empty ROOT_CACHE_USER must fail closed"
fi
pass "empty ROOT_CACHE_USER fails closed"

# --- dotenv baseline resolves into Persist EnvironmentFile keys ---
printf 'ROOT_CACHE_USER=cacheadmin\nROOT_CACHE_PASSWORD=s3cret\n' >"${ENV_DIR}/.env"
unset ROOT_CACHE_USER ROOT_CACHE_PASSWORD || true
cache_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" \
  || fail "valid dotenv should resolve"
grep -Fxq 'CACHE_ADMIN_USER=cacheadmin' "${OUT}" || fail "expected CACHE_ADMIN_USER from ROOT_CACHE_USER"
grep -Fxq 'CACHE_ADMIN_PASSWORD=s3cret' "${OUT}" || fail "expected CACHE_ADMIN_PASSWORD from ROOT_CACHE_PASSWORD"
if grep -Eq '^ROOT_CACHE_' "${OUT}"; then
  fail "staged EnvironmentFile must not echo ROOT_CACHE_* names"
fi
pass "dotenv baseline stages CACHE_ADMIN_USER/PASSWORD"

# --- shell overrides dotenv ---
printf 'ROOT_CACHE_USER=fromfile\nROOT_CACHE_PASSWORD=filepass\n' >"${ENV_DIR}/.env"
ROOT_CACHE_USER=fromshell ROOT_CACHE_PASSWORD=shellpass \
  cache_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" \
  || fail "shell override should resolve"
grep -Fxq 'CACHE_ADMIN_USER=fromshell' "${OUT}" || fail "shell ROOT_CACHE_USER should win"
grep -Fxq 'CACHE_ADMIN_PASSWORD=shellpass' "${OUT}" || fail "shell ROOT_CACHE_PASSWORD should win"
pass "shell overrides dotenv for Cache admin credentials"

# --- .env.override overlays .env; shell still wins ---
printf 'ROOT_CACHE_USER=fromfile\nROOT_CACHE_PASSWORD=filepass\n' >"${ENV_DIR}/.env"
printf 'ROOT_CACHE_USER=fromov\nROOT_CACHE_PASSWORD=ovpass\n' >"${ENV_DIR}/.env.override"
unset ROOT_CACHE_USER ROOT_CACHE_PASSWORD || true
cache_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" \
  || fail "override bag should resolve"
grep -Fxq 'CACHE_ADMIN_USER=fromov' "${OUT}" || fail "override ROOT_CACHE_USER should win over .env"
grep -Fxq 'CACHE_ADMIN_PASSWORD=ovpass' "${OUT}" || fail "override ROOT_CACHE_PASSWORD should win over .env"
ROOT_CACHE_USER=fromshell ROOT_CACHE_PASSWORD=shellpass \
  cache_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" \
  || fail "shell over override should resolve"
grep -Fxq 'CACHE_ADMIN_USER=fromshell' "${OUT}" || fail "shell must beat .env.override"
rm -f "${ENV_DIR}/.env.override"
pass ".env.override overlays .env; shell still wins"

# --- invalid dotenv grammar fails closed ---
printf 'export ROOT_CACHE_USER=nope\nROOT_CACHE_PASSWORD=x\n' >"${ENV_DIR}/.env"
unset ROOT_CACHE_USER ROOT_CACHE_PASSWORD || true
if cache_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" 2>"${TMP}/err-export"; then
  fail "export line must fail closed"
fi
pass "invalid dotenv (export) fails closed"

# --- absent .env still allows shell-only resolution ---
rm -f "${ENV_DIR}/.env"
ROOT_CACHE_USER=shellonly ROOT_CACHE_PASSWORD=shellpw \
  cache_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" \
  || fail "shell-only resolution should succeed without .env"
grep -Fxq 'CACHE_ADMIN_USER=shellonly' "${OUT}" || fail "shell-only USER missing"
grep -Fxq 'CACHE_ADMIN_PASSWORD=shellpw' "${OUT}" || fail "shell-only PASSWORD missing"
pass "shell-only Cache admin credentials without .env"

echo "All cache-admin-credentials unit tests passed."
