#!/usr/bin/env bash
# Acceptance Test: Identity handoff material staged on Host after Deploy (ADR-0057 / #251).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
# shellcheck source=../../lib/identity/identity-config.sh
source "${REPO_ROOT}/internals/lib/identity/identity-config.sh"
ISSUER_FQDN="$(identity_config_issuer_fqdn_for "${ENV_SLUG}")" \
  || fail "committed identity.json must validate for test Environment"

USER_NAME="${PLATFORM_USER:-platform}"
HV_ROOT="/host-volume"
CONFIG="${HV_ROOT}/components/handoff/identity.json"
ADMIN="${HV_ROOT}/components/handoff/identity-admin.env"

host_ssh "test -f '${CONFIG}'" \
  || fail "Identity config handoff missing on Host Volume"
host_ssh "grep -Fq '\"fqdn\": \"${ISSUER_FQDN}\"' '${CONFIG}'" \
  || fail "Identity config handoff fqdn mismatch on Host"
host_ssh "test -f '${ADMIN}'" \
  || fail "Identity admin handoff missing on Host Volume"
host_ssh "grep -Eq '^STATIC_API_KEY=.+' '${ADMIN}'" \
  || fail "Identity admin handoff missing STATIC_API_KEY"
host_ssh "grep -Eq '^ENCRYPTION_KEY=.+' '${ADMIN}'" \
  || fail "Identity admin handoff missing ENCRYPTION_KEY"
host_ssh "grep -Eq '^IDENTITY_ADMIN_EMAIL=.+' '${ADMIN}'" \
  || fail "Identity admin handoff missing IDENTITY_ADMIN_EMAIL"
host_ssh "grep -Fxq 'APP_URL=https://${ISSUER_FQDN}' '${ADMIN}'" \
  || fail "Identity admin handoff APP_URL mismatch"
pass "Identity config + admin material present in Host handoff after Deploy"
