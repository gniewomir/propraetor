#!/usr/bin/env bash
# Identity admin credentials resolve/stage helper (ADR-0057 / #251).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=identity-admin-credentials.sh
source "${REPO_ROOT}/internals/lib/identity/identity-admin-credentials.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/identity-admin-creds.XXXXXX")"
ENV_DIR="${TMP}/env"
OUT="${TMP}/identity-admin.env"
ISSUER="auth.enraged.dev"
mkdir -p "${ENV_DIR}"
trap 'rm -rf "${TMP}"; unset ROOT_IDENTITY_API_KEY ROOT_IDENTITY_ENCRYPTION_KEY ROOT_IDENTITY_ADMIN_EMAIL || true' EXIT

unset ROOT_IDENTITY_API_KEY ROOT_IDENTITY_ENCRYPTION_KEY ROOT_IDENTITY_ADMIN_EMAIL || true

if identity_admin_credentials_dotenv_for "${ENV_DIR}" "${ISSUER}" "${OUT}" \
  >/dev/null 2>"${TMP}/err-missing"; then
  fail "missing ROOT_IDENTITY_* must fail closed"
fi
grep -Eqi 'ROOT_IDENTITY_|fail closed|missing' "${TMP}/err-missing" \
  || fail "missing creds rejection unclear: $(cat "${TMP}/err-missing")"
pass "missing Identity admin credentials fail closed"

printf 'ROOT_IDENTITY_API_KEY=short\nROOT_IDENTITY_ENCRYPTION_KEY=enc\nROOT_IDENTITY_ADMIN_EMAIL=ops@example.com\n' \
  >"${ENV_DIR}/.env"
if identity_admin_credentials_dotenv_for "${ENV_DIR}" "${ISSUER}" "${OUT}" \
  >/dev/null 2>&1; then
  fail "ROOT_IDENTITY_API_KEY shorter than 16 chars must fail closed"
fi
pass "short ROOT_IDENTITY_API_KEY fails closed"

printf 'ROOT_IDENTITY_API_KEY=0123456789abcdef\nROOT_IDENTITY_ENCRYPTION_KEY=enc\nROOT_IDENTITY_ADMIN_EMAIL=not-an-email\n' \
  >"${ENV_DIR}/.env"
if identity_admin_credentials_dotenv_for "${ENV_DIR}" "${ISSUER}" "${OUT}" \
  >/dev/null 2>&1; then
  fail "invalid ROOT_IDENTITY_ADMIN_EMAIL must fail closed"
fi
pass "invalid ROOT_IDENTITY_ADMIN_EMAIL fails closed"

printf 'ROOT_IDENTITY_API_KEY=0123456789abcdef\nROOT_IDENTITY_ENCRYPTION_KEY=enckey\nROOT_IDENTITY_ADMIN_EMAIL=ops@example.com\n' \
  >"${ENV_DIR}/.env"
unset ROOT_IDENTITY_API_KEY ROOT_IDENTITY_ENCRYPTION_KEY ROOT_IDENTITY_ADMIN_EMAIL || true
identity_admin_credentials_dotenv_for "${ENV_DIR}" "${ISSUER}" "${OUT}" \
  || fail "valid Identity admin credentials must stage"
grep -Fxq 'STATIC_API_KEY=0123456789abcdef' "${OUT}" \
  || fail "expected STATIC_API_KEY from ROOT_IDENTITY_API_KEY"
grep -Fxq 'ENCRYPTION_KEY=enckey' "${OUT}" \
  || fail "expected ENCRYPTION_KEY from ROOT_IDENTITY_ENCRYPTION_KEY"
grep -Fxq 'IDENTITY_ADMIN_EMAIL=ops@example.com' "${OUT}" \
  || fail "expected IDENTITY_ADMIN_EMAIL from ROOT_IDENTITY_ADMIN_EMAIL"
grep -Fxq 'APP_URL=https://auth.enraged.dev' "${OUT}" \
  || fail "expected derived APP_URL"
if grep -Eq '^ROOT_IDENTITY_' "${OUT}"; then
  fail "staged EnvironmentFile must not echo ROOT_IDENTITY_* names"
fi
pass "valid credentials stage Pocket ID / Setup keys with derived APP_URL"

printf 'ROOT_IDENTITY_API_KEY=fromfile012345\nROOT_IDENTITY_ENCRYPTION_KEY=fileenc\nROOT_IDENTITY_ADMIN_EMAIL=file@example.com\n' \
  >"${ENV_DIR}/.env"
ROOT_IDENTITY_API_KEY=fromshell01234567 \
ROOT_IDENTITY_ENCRYPTION_KEY=shellenc \
ROOT_IDENTITY_ADMIN_EMAIL=shell@example.com \
  identity_admin_credentials_dotenv_for "${ENV_DIR}" "${ISSUER}" "${OUT}" \
  || fail "shell override should win"
grep -Fxq 'STATIC_API_KEY=fromshell01234567' "${OUT}" \
  || fail "shell ROOT_IDENTITY_API_KEY should win"
grep -Fxq 'IDENTITY_ADMIN_EMAIL=shell@example.com' "${OUT}" \
  || fail "shell ROOT_IDENTITY_ADMIN_EMAIL should win"
pass "shell overrides dotenv bag for Identity admin credentials"

echo "All identity-admin-credentials unit tests passed."
