#!/usr/bin/env bash
# Offline tests: Edge ACME EnvironmentFile install from staged dotenv (ADR-0045).
# Ambient ACME_ENV / USER_NAME → temp dirs (no SSH / live Host).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=edge-acme-env-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/edge-acme-env-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/edge-acme-env.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

ACME_ENV="${TMP}/acme/environment"
USER_NAME="offline-test-user"
STAGE="${TMP}/staged-acme.env"

# --- install places staged dotenv into Host ACME EnvironmentFile ---
mkdir -p "$(dirname "${ACME_ENV}")"
printf '%s\n' 'EDGE_ACME_DIRECTORY=production' 'EDGE_ACME_EMAIL=ops@example.com' >"${STAGE}"
edge_install_acme_env "${STAGE}" || fail "edge_install_acme_env should succeed"
[[ -f "${ACME_ENV}" ]] || fail "expected ACME_ENV at ${ACME_ENV}"
grep -Fxq 'EDGE_ACME_DIRECTORY=production' "${ACME_ENV}" || fail "missing DIRECTORY line"
grep -Fxq 'EDGE_ACME_EMAIL=ops@example.com' "${ACME_ENV}" || fail "missing EMAIL line"
pass "install places staged dotenv into Host ACME EnvironmentFile"

# --- install creates parent ACME dir when missing ---
rm -rf "${TMP}/acme"
printf '%s\n' 'EDGE_ACME_DIRECTORY=staging' >"${STAGE}"
edge_install_acme_env "${STAGE}" || fail "install should mkdir parent"
[[ -f "${ACME_ENV}" ]] || fail "expected ACME_ENV after mkdir"
grep -Fxq 'EDGE_ACME_DIRECTORY=staging' "${ACME_ENV}" || fail "expected staging after install"
pass "install creates parent ACME dir when missing"

# --- missing staged file leaves existing EnvironmentFile; creates staging default if absent ---
rm -f "${STAGE}"
printf '%s\n' 'EDGE_ACME_DIRECTORY=production' 'EDGE_ACME_EMAIL=keep@example.com' >"${ACME_ENV}"
edge_install_acme_env "${STAGE}" || fail "missing stage should not fail"
grep -Fxq 'EDGE_ACME_EMAIL=keep@example.com' "${ACME_ENV}" \
  || fail "existing ACME_ENV must remain when stage missing"
rm -f "${ACME_ENV}"
edge_install_acme_env "${STAGE}" || fail "missing stage + missing ACME_ENV should not fail"
[[ -f "${ACME_ENV}" ]] || fail "expected default ACME_ENV created"
grep -Fxq 'EDGE_ACME_DIRECTORY=staging' "${ACME_ENV}" \
  || fail "new ACME_ENV should default to staging when stage missing"
if grep -q 'EDGE_ACME_EMAIL=' "${ACME_ENV}"; then
  fail "default ACME_ENV must not invent an email"
fi
pass "missing staged file leaves existing; creates staging default if absent"

# --- edge-acme.service wires EnvironmentFile to Host ACME path ---
UNIT="${REPO_ROOT}/internals/components/edge/systemd/edge-acme.service"
[[ -f "${UNIT}" ]] || fail "missing edge-acme.service"
grep -Eq '^EnvironmentFile=/host-volume/components/edge/persist/acme/environment$' "${UNIT}" \
  || fail "edge-acme.service must EnvironmentFile= Host ACME environment path"
pass "edge-acme.service consumes Host ACME EnvironmentFile"

echo "All edge-acme-env-host offline tests passed."
