#!/usr/bin/env bash
# Unit tests: Environment dotenv bag merge (.env + .env.override).
# Seam: environment_dotenv_bag ENV_DIR — file merge only; no shell overlay.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=environment-dotenv.sh
source "${REPO_ROOT}/internals/lib/environment/environment-dotenv.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/env-dotenv.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
ENV_DIR="${TMP}/env"
mkdir -p "${ENV_DIR}"

# --- absent both files → empty bag ---
got="$(environment_dotenv_bag "${ENV_DIR}")" || fail "absent files should succeed"
[[ -z "${got}" ]] || fail "absent files must yield empty bag, got: ${got}"
pass "absent .env and .env.override → empty bag"

# --- .env only ---
printf 'A=from-env\nB=env-b\n' >"${ENV_DIR}/.env"
got="$(environment_dotenv_bag "${ENV_DIR}")" || fail ".env-only should succeed"
printf '%s\n' "${got}" | grep -Fxq 'A=from-env' || fail "expected A from .env"
printf '%s\n' "${got}" | grep -Fxq 'B=env-b' || fail "expected B from .env"
pass ".env only loads baseline"

# --- .env.override overlays .env on collision; keeps unique keys from both ---
printf 'A=from-env\nB=env-b\n' >"${ENV_DIR}/.env"
printf 'A=from-override\nC=ov-c\n' >"${ENV_DIR}/.env.override"
got="$(environment_dotenv_bag "${ENV_DIR}")" || fail "merge should succeed"
printf '%s\n' "${got}" | grep -Fxq 'A=from-override' || fail "override must win on A"
printf '%s\n' "${got}" | grep -Fxq 'B=env-b' || fail "B from .env must remain"
printf '%s\n' "${got}" | grep -Fxq 'C=ov-c' || fail "C from override must appear"
if printf '%s\n' "${got}" | grep -Fxq 'A=from-env'; then
  fail "overridden .env value must not remain"
fi
pass ".env.override takes precedence over .env"

# --- override-only (no .env) ---
rm -f "${ENV_DIR}/.env"
printf 'X=only-override\n' >"${ENV_DIR}/.env.override"
got="$(environment_dotenv_bag "${ENV_DIR}")" || fail "override-only should succeed"
printf '%s\n' "${got}" | grep -Fxq 'X=only-override' || fail "expected X from override"
pass ".env.override alone loads"

# --- invalid .env fails closed ---
printf 'export A=nope\n' >"${ENV_DIR}/.env"
rm -f "${ENV_DIR}/.env.override"
if environment_dotenv_bag "${ENV_DIR}" >/dev/null 2>"${TMP}/err-env"; then
  fail "invalid .env must fail closed"
fi
grep -Eqi 'export|invalid' "${TMP}/err-env" \
  || fail "invalid .env rejection unclear: $(cat "${TMP}/err-env")"
pass "invalid .env fails closed"

# --- invalid .env.override fails closed ---
printf 'A=ok\n' >"${ENV_DIR}/.env"
printf 'export B=nope\n' >"${ENV_DIR}/.env.override"
if environment_dotenv_bag "${ENV_DIR}" >/dev/null 2>"${TMP}/err-ov"; then
  fail "invalid .env.override must fail closed"
fi
grep -Eqi 'export|invalid' "${TMP}/err-ov" \
  || fail "invalid override rejection unclear: $(cat "${TMP}/err-ov")"
pass "invalid .env.override fails closed"

echo "All environment-dotenv unit tests passed."
