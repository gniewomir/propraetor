#!/usr/bin/env bash
# Acceptance Test: Identity issuer FQDN reachable over HTTPS via Edge (ADR-0057 / #252).
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
  || fail "committed identity.json must validate for Environment ${ENV_SLUG}"

# Public HTTPS through Edge → Identity Service Network (OIDC discovery).
body="$(curl -kfsS --max-time 30 --resolve "${ISSUER_FQDN}:443:${IP}" \
  "https://${ISSUER_FQDN}/.well-known/openid-configuration" 2>/dev/null)" \
  || fail "HTTPS GET issuer OIDC discovery failed for ${ISSUER_FQDN}"
printf '%s\n' "${body}" | grep -Fq "\"issuer\":\"https://${ISSUER_FQDN}\"" \
  || printf '%s\n' "${body}" | grep -Fq "\"issuer\": \"https://${ISSUER_FQDN}\"" \
  || fail "OIDC discovery issuer must match ${ISSUER_FQDN}; body=${body}"
pass "issuer FQDN ${ISSUER_FQDN} reachable over HTTPS via Edge proxy to Identity"
