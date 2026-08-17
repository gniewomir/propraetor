#!/usr/bin/env bash
# Acceptance Test: Domain fronts + placeholder PEMs + /healthcheck Tier A+B (#78 / #79)
# Tier A: shape via --resolve + insecure trust.
# Tier B: live ACME staging via operator OpenSSL + vendored staging roots (when DNS-ready).
# No Workload Setup.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

# shellcheck source=../../lib/domains/domains.sh
source "${REPO_ROOT}/internals/lib/domains/domains.sh"
# shellcheck source=../../lib/domains/domain_front_target.sh
source "${REPO_ROOT}/internals/lib/domains/domain_front_target.sh"
# shellcheck source=../../lib/domains/domain_front_staging_hc.sh
source "${REPO_ROOT}/internals/lib/domains/domain_front_staging_hc.sh"

DATA_ROOT=/host-volume/components/edge/persist
DOMAINS_HOST="${DATA_ROOT}/domains"
CERTS_HOST="${DATA_ROOT}/certs"
STAGING_CA="${REPO_ROOT}/internals/test/acceptance/fixtures/le-staging-roots/le-staging-roots.pem"

EXPECTED="$(domains_acme_fqdns_for "${PLATFORM_ENV:-test}")"
if [[ -z "${EXPECTED}" ]]; then
  echo "SOFT-SKIP: empty Domain want-list — no Domain fronts for Tier A/B (#79)"
  exit 0
fi

SELECT_OUT="$(printf '%s\n' "${EXPECTED}" | domain_front_select_target "${IP}")"
FQDN="$(printf '%s\n' "${SELECT_OUT}" | awk '{print $1}')"
DNS_READY="$(printf '%s\n' "${SELECT_OUT}" | awk '{print $2}')"
[[ -n "${FQDN}" ]] || fail "want-list non-empty but no FQDN selected"
[[ "${DNS_READY}" == "ready" || "${DNS_READY}" == "not-ready" ]] \
  || fail "unexpected DNS-ready flag '${DNS_READY}'"

"${REPO_ROOT}/internals/ensure-components.sh" pre-workloads --env "${PLATFORM_ENV:-test}"

# --- Host layout: Domain front + placeholder PEMs ---
host_ssh "test ! -e '${DOMAINS_HOST}/00-empty.conf'" \
  || fail "legacy domains/00-empty.conf stub must be absent"
host_ssh "test -f '${DOMAINS_HOST}/${FQDN}.conf'" \
  || fail "Domain front missing for ${FQDN}"
host_ssh \
  "test -f '${CERTS_HOST}/${FQDN}/fullchain.pem' && test -f '${CERTS_HOST}/${FQDN}/privkey.pem'" \
  || fail "placeholder PEMs missing for ${FQDN}"
front="$(host_ssh "cat '${DOMAINS_HOST}/${FQDN}.conf'")"
echo "${front}" | grep -Fq "include /etc/nginx/edge-routes/*--${FQDN}.conf;" \
  || fail "Domain front must include Workload Route fragments for ${FQDN}"
pass "Domain front and placeholder PEMs present for ${FQDN}"

# Complete pair survives re-ensure (ADR-0029).
full_before="$(host_ssh "sha256sum '${CERTS_HOST}/${FQDN}/fullchain.pem'")"
key_before="$(host_ssh "sha256sum '${CERTS_HOST}/${FQDN}/privkey.pem'")"
front_before="$(host_ssh "sha256sum '${DOMAINS_HOST}/${FQDN}.conf'")"
"${REPO_ROOT}/internals/ensure-components.sh" pre-workloads --env "${PLATFORM_ENV:-test}"
full_after="$(host_ssh "sha256sum '${CERTS_HOST}/${FQDN}/fullchain.pem'")"
key_after="$(host_ssh "sha256sum '${CERTS_HOST}/${FQDN}/privkey.pem'")"
front_after="$(host_ssh "sha256sum '${DOMAINS_HOST}/${FQDN}.conf'")"
[[ "${full_before}" == "${full_after}" ]] || fail "re-ensure clobbered complete fullchain.pem"
[[ "${key_before}" == "${key_after}" ]] || fail "re-ensure clobbered complete privkey.pem"
[[ "${front_before}" == "${front_after}" ]] || fail "re-ensure churned Domain-front drop-in"
pass "re-ensure leaves complete PEMs and Domain-front drop-in untouched"

# --- Tier A: /healthcheck over HTTPS (placeholder trust) ---
umask 077
HC_BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/platform-hc-XXXXXX")"
STAGING_OUT="$(mktemp "${TMPDIR:-/tmp}/platform-stg-XXXXXX")"
# Isolation cleanup registered before any survive-Deploy ACME probe write below.
trap 'rm -f "${HC_BODY_FILE}" "${STAGING_OUT}"; acceptance_wl_cleanup' EXIT
hc_code=""
hc_ctype=""
hc_body=""
for _ in $(seq 1 30); do
  hc_code="$(curl -skS -o "${HC_BODY_FILE}" -w '%{http_code}' --connect-timeout 10 --max-time 15 \
    --resolve "${FQDN}:443:${IP}" "https://${FQDN}/healthcheck" 2>/dev/null || true)"
  if [[ "${hc_code}" =~ ^[1-5][0-9]{2}$ ]]; then
    hc_ctype="$(curl -skS -o /dev/null -w '%{content_type}' --connect-timeout 10 --max-time 15 \
      --resolve "${FQDN}:443:${IP}" "https://${FQDN}/healthcheck" 2>/dev/null || true)"
    hc_body="$(cat "${HC_BODY_FILE}" 2>/dev/null || true)"
    break
  fi
  sleep 1
done
[[ "${hc_code}" == "200" ]] || fail "/healthcheck expected HTTP 200, got '${hc_code}'"
echo "${hc_ctype}" | grep -qi 'text/plain' \
  || fail "/healthcheck expected text/plain, got '${hc_ctype}'"
[[ "${hc_body}" == "ok" ]] || fail "/healthcheck expected body 'ok', got '${hc_body}'"
pass "Domain-front /healthcheck → 200 text/plain ok (no Workload)"

# --- :80 redirect ---
redir="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --connect-timeout 10 --max-time 15 \
  --resolve "${FQDN}:80:${IP}" "http://${FQDN}/healthcheck")"
redir_code="${redir%% *}"
redir_url="${redir#* }"
[[ "${redir_code}" == "301" || "${redir_code}" == "302" ]] \
  || fail "expected redirect on :80 for Domain front, got '${redir}'"
echo "${redir_url}" | grep -q "^https://${FQDN}/healthcheck" \
  || fail "redirect target expected https://${FQDN}/healthcheck, got '${redir_url}'"
pass ":80 redirects non-ACME to HTTPS for Domain front"

# --- Tier B: live ACME staging (DNS-ready only) ---
TIER_B_PROVEN=0
if [[ "${DNS_READY}" != "ready" ]]; then
  echo "SOFT-SKIP: Tier B — ${FQDN} A record does not answer at Reserved IP ${IP}; Domain-front shape only (not HTTPS+ACME proven) (#79)"
else
  [[ -f "${STAGING_CA}" ]] || fail "missing vendored staging roots: ${STAGING_CA}"
  command -v openssl >/dev/null 2>&1 || fail "openssl required for Tier B staging-root verify"
  tier_b_ok=0
  for _ in $(seq 1 120); do
    : >"${STAGING_OUT}"
    set +e
    printf 'GET /healthcheck HTTP/1.0\r\nHost: %s\r\n\r\n' "${FQDN}" \
      | openssl s_client \
        -connect "${IP}:443" \
        -servername "${FQDN}" \
        -CAfile "${STAGING_CA}" \
        -verify_return_error \
        -quiet \
        2>/dev/null >"${STAGING_OUT}"
    stg_rc=$?
    set -e
    if domain_front_staging_hc_ok "${stg_rc}" "${STAGING_OUT}"; then
      tier_b_ok=1
      break
    fi
    sleep 2
  done
  if [[ "${tier_b_ok}" -ne 1 ]]; then
    fail "Tier B: ${FQDN} still not staging-trusted /healthcheck after ~240s (openssl rc last=${stg_rc:-?}; still placeholder or verify failure)"
  fi
  pass "Tier B: Domain-front /healthcheck verifies against Let’s Encrypt staging roots"
  TIER_B_PROVEN=1
fi

# --- ACME HTTP-01 still works ---
TOKEN="domain-front-acme-probe"
acceptance_data_track "components/edge/persist/acme-www/.well-known/acme-challenge/${TOKEN}"
host_ssh bash -s <<REMOTE
set -euo pipefail
TOKEN_PATH=${DATA_ROOT}/acme-www/.well-known/acme-challenge/${TOKEN}
mkdir -p "\$(dirname "\${TOKEN_PATH}")"
printf '%s\n' '${TOKEN}' >"\${TOKEN_PATH}"
chown -R platform:platform ${DATA_ROOT}/acme-www
REMOTE
# Retry: Edge may briefly RST during front-door reload (same window as /healthcheck).
acme_body=""
for _ in $(seq 1 30); do
  acme_body="$(curl -sS --connect-timeout 10 --max-time 15 \
    --resolve "${FQDN}:80:${IP}" "http://${FQDN}/.well-known/acme-challenge/${TOKEN}" 2>/dev/null || true)"
  [[ "${acme_body}" == "${TOKEN}" ]] && break
  sleep 1
done
[[ "${acme_body}" == "${TOKEN}" ]] || fail "ACME path on :80 broken after Domain front (got '${acme_body}')"
pass "ACME HTTP-01 on :80 still works alongside Domain-front redirect"

# --- ACME reload does not mutate Domain-front drop-in ---
front_pre_acme="$(host_ssh "sha256sum '${DOMAINS_HOST}/${FQDN}.conf'")"
host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM="\$(id -u platform)"
export XDG_RUNTIME_DIR="/run/user/\${UID_NUM}"
systemctl start "user@\${UID_NUM}.service"
runuser -u platform -- env XDG_RUNTIME_DIR="\$XDG_RUNTIME_DIR" \
  systemctl --user stop edge-acme.service 2>/dev/null || true
runuser -u platform -- env XDG_RUNTIME_DIR="\$XDG_RUNTIME_DIR" EDGE_ACME_ISSUE=0 \
  /host-volume/components/edge/acme-run.sh
REMOTE
front_post_acme="$(host_ssh "sha256sum '${DOMAINS_HOST}/${FQDN}.conf'")"
[[ "${front_pre_acme}" == "${front_post_acme}" ]] \
  || fail "ACME must not mutate Domain-front drop-in"
pass "ACME reload leaves Domain-front drop-in unchanged"

if [[ "${TIER_B_PROVEN}" -eq 1 ]]; then
  echo "All Domain-front Acceptance checks passed (HTTPS+ACME staging proven)."
else
  echo "All Domain-front Acceptance checks passed (Tier A only; HTTPS+ACME not claimed)."
fi
