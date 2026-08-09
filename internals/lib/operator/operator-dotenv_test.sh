#!/usr/bin/env bash
# Unit test: repo-root operator dotenv load (ADR-0038).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=operator-dotenv.sh
source "${REPO_ROOT}/internals/lib/operator/operator-dotenv.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/operator-dotenv-test.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# Missing .env is a no-op
unset DIGITALOCEAN_TOKEN PROPRAETOR_PUBLIC_KEY_PATH PROPRAETOR_PRIVATE_KEY_PATH PROPRAETOR_ACME_EMAIL
operator_dotenv_load "${TMP}" || fail "missing .env should succeed"
[[ -z "${DIGITALOCEAN_TOKEN:-}" ]] || fail "missing .env must not set DIGITALOCEAN_TOKEN"
pass "missing .env is no-op"

# Baseline fills unset keys; shell non-empty wins; empty file value is unset
printf '%s\n' \
  'DIGITALOCEAN_TOKEN=from-file' \
  'PROPRAETOR_PUBLIC_KEY_PATH=/tmp/from-file.pub' \
  'PROPRAETOR_PRIVATE_KEY_PATH=' \
  'PROPRAETOR_ACME_EMAIL=from-file@example.com' \
  >"${TMP}/.env"

unset DIGITALOCEAN_TOKEN PROPRAETOR_PUBLIC_KEY_PATH PROPRAETOR_PRIVATE_KEY_PATH PROPRAETOR_ACME_EMAIL
export DIGITALOCEAN_TOKEN=from-shell
operator_dotenv_load "${TMP}" || fail "valid .env should load"
[[ "${DIGITALOCEAN_TOKEN}" == "from-shell" ]] || fail "shell must win over file"
[[ "${PROPRAETOR_PUBLIC_KEY_PATH}" == "/tmp/from-file.pub" ]] \
  || fail "file should fill unset public path"
[[ -z "${PROPRAETOR_PRIVATE_KEY_PATH:-}" ]] \
  || fail "empty file value must leave private path unset"
[[ "${PROPRAETOR_ACME_EMAIL}" == "from-file@example.com" ]] \
  || fail "file should fill unset ACME email"
pass "shell wins; empty file value unset; baseline fills"

# Shell wins for PROPRAETOR_ACME_EMAIL
printf '%s\n' 'PROPRAETOR_ACME_EMAIL=from-file@example.com' >"${TMP}/.env"
unset PROPRAETOR_ACME_EMAIL
export PROPRAETOR_ACME_EMAIL=from-shell@example.com
operator_dotenv_load "${TMP}" || fail "ACME email .env should load"
[[ "${PROPRAETOR_ACME_EMAIL}" == "from-shell@example.com" ]] \
  || fail "shell ACME email must win over file"
pass "shell wins for PROPRAETOR_ACME_EMAIL"

# Unknown key fails closed
printf '%s\n' 'DIGITALOCEAN_TOKEN=x' 'SSH_IDENTITY=/tmp/x' >"${TMP}/.env"
unset DIGITALOCEAN_TOKEN PROPRAETOR_PUBLIC_KEY_PATH PROPRAETOR_PRIVATE_KEY_PATH PROPRAETOR_ACME_EMAIL
if operator_dotenv_load "${TMP}" >/dev/null 2>&1; then
  fail "unknown key SSH_IDENTITY must fail closed"
fi
pass "unknown key fails closed"

# TF_VAR_host_root_ssh_public_key in file fails closed
printf '%s\n' 'TF_VAR_host_root_ssh_public_key=ssh-ed25519 AAAA' >"${TMP}/.env"
if operator_dotenv_load "${TMP}" >/dev/null 2>&1; then
  fail "TF_VAR_host_root_ssh_public_key in .env must fail closed"
fi
pass "derived TF_VAR in .env fails closed"

# Invalid dotenv grammar fails closed
printf '%s\n' 'export DIGITALOCEAN_TOKEN=nope' >"${TMP}/.env"
if operator_dotenv_load "${TMP}" >/dev/null 2>&1; then
  fail "export line must fail closed"
fi
pass "invalid dotenv grammar fails closed"

echo "All operator-dotenv checks passed."
