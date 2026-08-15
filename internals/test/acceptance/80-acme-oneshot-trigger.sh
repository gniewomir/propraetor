#!/usr/bin/env bash
# Acceptance Test: ensure-components stages Domain ACME FQDNs; Edge Setup installs want-list and starts oneshot (ADR-0023 / #56 / #131)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

# shellcheck source=../../lib/domains/domains.sh
source "${REPO_ROOT}/internals/lib/domains/domains.sh"
EXPECTED="$(domains_acme_fqdns_for "${PLATFORM_ENV:-test}")"

before="$(host_ssh \
  "cat /host-volume/components/edge/persist/acme/last-run 2>/dev/null || echo none")"
sleep 2

"${REPO_ROOT}/internals/ensure-components.sh" post-workloads --env "${PLATFORM_ENV:-test}"

want="$(host_ssh "cat /host-volume/components/edge/persist/acme/want-list")"
if [[ -n "${EXPECTED}" ]]; then
  while IFS= read -r fqdn; do
    [[ -n "${fqdn}" ]] || continue
    echo "${want}" | grep -qx "${fqdn}" \
      || fail "want-list missing Domain FQDN ${fqdn} (got: ${want})"
  done <<<"${EXPECTED}"
  pass "ACME want-list matches Domain assignment FQDNs"
else
  [[ -z "$(echo "${want}" | tr -d '[:space:]')" ]] \
    || fail "empty Domain assignment but want-list non-empty: ${want}"
  pass "ACME want-list empty when Environment has zero Domains"
fi

after="missing"
for _ in $(seq 1 30); do
  after="$(host_ssh \
    "cat /host-volume/components/edge/persist/acme/last-run 2>/dev/null || echo missing")"
  if [[ "${after}" != "missing" && "${after}" != "${before}" ]]; then
    break
  fi
  sleep 1
done
[[ "${after}" != "missing" ]] || fail "ACME oneshot did not write last-run stamp"
[[ "${after}" != "${before}" ]] || fail "ACME oneshot was not triggered (last-run unchanged: ${after})"
pass "ensure-components starts Edge ACME oneshot after Domain want-list is installed"

timer="$(host_ssh bash -s <<'REMOTE'
UID_NUM=$(id -u platform)
export XDG_RUNTIME_DIR=/run/user/${UID_NUM}
if runuser -u platform -- env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR \
  systemctl --user --quiet is-active edge-acme.timer; then
  echo active
else
  echo inactive
fi
REMOTE
)"
[[ "${timer}" == "active" ]] || fail "periodic edge-acme.timer should remain active"
pass "Periodic systemd user timer remains in place for renewals"

# Cert material when DNS already answers at the Reserved IP (ADR-0023).
while IFS= read -r fqdn; do
  [[ -n "${fqdn}" ]] || continue
  dns_hits=0
  while IFS= read -r resolved; do
    [[ -n "${resolved}" ]] || continue
    if [[ "${resolved}" == "${IP}" ]]; then
      dns_hits=1
      break
    fi
  done < <(dig +short "${fqdn}" A 2>/dev/null || true)
  if [[ "${dns_hits}" -ne 1 ]]; then
    pass "skip cert assert for ${fqdn} (DNS does not answer at Reserved IP)"
    continue
  fi
  pem_ok=0
  for _ in $(seq 1 120); do
    if host_ssh \
      "test -f /host-volume/components/edge/persist/certs/${fqdn}/fullchain.pem \
       && test -f /host-volume/components/edge/persist/certs/${fqdn}/privkey.pem"; then
      pem_ok=1
      break
    fi
    sleep 2
  done
  [[ "${pem_ok}" -eq 1 ]] \
    || fail "DNS-ready managed name ${fqdn} missing Edge cert PEMs after ACME wait"
  pass "cert material present for DNS-ready managed name ${fqdn}"
done <<<"${EXPECTED}"

# Unmanaged name must not appear on want-list.
echo "${want}" | grep -qx "unmanaged.example.test" \
  && fail "unmanaged name must not be on ACME want-list" || true
pass "unmanaged names are absent from ACME want-list"

publishers="$(host_ssh \
  "ss -ltnp | grep -E ':80|:443' || true")"
echo "${publishers}" | grep -qi 'acme\|lego\|certbot' \
  && fail "ACME client appears to be listening on :80/:443" || true
pass "ACME does not bind :80/:443 (Edge publishes those ports)"
