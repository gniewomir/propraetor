#!/usr/bin/env bash
# Unit tests: Database admin credentials resolve (ADR-0049 / #188).
# Offline: temp Environment dir + shell overrides. No Host / SSH.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=database-admin-credentials.sh
source "${REPO_ROOT}/internals/lib/database/database-admin-credentials.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/db-admin-creds.XXXXXX")"
trap 'rm -rf "${TMP}"; unset ROOT_DB_USER ROOT_DB_PASSWORD || true' EXIT
ENV_DIR="${TMP}/env"
mkdir -p "${ENV_DIR}"
OUT="${TMP}/out.env"

unset ROOT_DB_USER ROOT_DB_PASSWORD || true

# --- missing both keys fails closed ---
: >"${ENV_DIR}/.env"
if database_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" 2>"${TMP}/err-missing"; then
  fail "missing ROOT_DB_* must fail closed"
fi
grep -Eqi 'ROOT_DB_USER|ROOT_DB_PASSWORD|fail closed|missing' "${TMP}/err-missing" \
  || fail "missing-keys rejection unclear: $(cat "${TMP}/err-missing")"
[[ ! -e "${OUT}" ]] || fail "outfile must not exist after missing-keys failure"
pass "missing both Database admin credentials fails closed"

# --- missing password fails closed ---
printf 'ROOT_DB_USER=dbadmin\n' >"${ENV_DIR}/.env"
if database_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" 2>"${TMP}/err-pw"; then
  fail "missing ROOT_DB_PASSWORD must fail closed"
fi
grep -Eqi 'ROOT_DB_PASSWORD' "${TMP}/err-pw" \
  || fail "missing-password rejection unclear: $(cat "${TMP}/err-pw")"
pass "missing ROOT_DB_PASSWORD fails closed"

# --- missing user fails closed ---
printf 'ROOT_DB_PASSWORD=secret\n' >"${ENV_DIR}/.env"
if database_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" 2>"${TMP}/err-user"; then
  fail "missing ROOT_DB_USER must fail closed"
fi
grep -Eqi 'ROOT_DB_USER' "${TMP}/err-user" \
  || fail "missing-user rejection unclear: $(cat "${TMP}/err-user")"
pass "missing ROOT_DB_USER fails closed"

# --- empty values fail closed ---
printf 'ROOT_DB_USER=\nROOT_DB_PASSWORD=secret\n' >"${ENV_DIR}/.env"
if database_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" 2>"${TMP}/err-empty"; then
  fail "empty ROOT_DB_USER must fail closed"
fi
pass "empty ROOT_DB_USER fails closed"

# --- dotenv baseline resolves into Postgres EnvironmentFile keys ---
printf 'ROOT_DB_USER=dbadmin\nROOT_DB_PASSWORD=s3cret\n' >"${ENV_DIR}/.env"
unset ROOT_DB_USER ROOT_DB_PASSWORD || true
database_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" \
  || fail "valid dotenv should resolve"
grep -Fxq 'POSTGRES_USER=dbadmin' "${OUT}" || fail "expected POSTGRES_USER from ROOT_DB_USER"
grep -Fxq 'POSTGRES_PASSWORD=s3cret' "${OUT}" || fail "expected POSTGRES_PASSWORD from ROOT_DB_PASSWORD"
if grep -Eq '^ROOT_DB_' "${OUT}"; then
  fail "staged EnvironmentFile must not echo ROOT_DB_* names (Postgres image contract)"
fi
pass "dotenv baseline stages POSTGRES_USER/PASSWORD"

# --- shell overrides dotenv ---
printf 'ROOT_DB_USER=fromfile\nROOT_DB_PASSWORD=filepass\n' >"${ENV_DIR}/.env"
ROOT_DB_USER=fromshell ROOT_DB_PASSWORD=shellpass \
  database_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" \
  || fail "shell override should resolve"
grep -Fxq 'POSTGRES_USER=fromshell' "${OUT}" || fail "shell ROOT_DB_USER should win"
grep -Fxq 'POSTGRES_PASSWORD=shellpass' "${OUT}" || fail "shell ROOT_DB_PASSWORD should win"
pass "shell overrides dotenv for Database admin credentials"

# --- invalid dotenv grammar fails closed ---
printf 'export ROOT_DB_USER=nope\nROOT_DB_PASSWORD=x\n' >"${ENV_DIR}/.env"
unset ROOT_DB_USER ROOT_DB_PASSWORD || true
if database_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" 2>"${TMP}/err-export"; then
  fail "export line must fail closed"
fi
pass "invalid dotenv (export) fails closed"

# --- absent .env still allows shell-only resolution ---
rm -f "${ENV_DIR}/.env"
ROOT_DB_USER=shellonly ROOT_DB_PASSWORD=shellpw \
  database_admin_credentials_dotenv_for "${ENV_DIR}" "${OUT}" \
  || fail "shell-only resolution should succeed without .env"
grep -Fxq 'POSTGRES_USER=shellonly' "${OUT}" || fail "shell-only USER missing"
grep -Fxq 'POSTGRES_PASSWORD=shellpw' "${OUT}" || fail "shell-only PASSWORD missing"
pass "shell-only Database admin credentials without .env"

echo "All database-admin-credentials unit tests passed."
