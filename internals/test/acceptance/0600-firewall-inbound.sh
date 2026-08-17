#!/usr/bin/env bash
# Acceptance Test: Firewall inbound — whitelist reachable; deny canaries not
# (ADR-0030). Cloud Firewall is before the Host (default deny + allow-set).
# Deny probe: Host SYN capture + operator nc; forged path replies fall back to
# allow-set exclusion (never treat forged SYN-ACK as Firewall allow).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session

if ping -c 2 -W 5 "${IP}" >/dev/null 2>&1; then
  pass "inbound ICMP reaches Host"
else
  fail "inbound ICMP to ${IP} failed"
fi

# 1) Whitelist reachable
for port in "${PLATFORM_SSH_PORT}" 80 443; do
  probe_allowed_tcp "${port}"
done

# 2) Fixed canaries not reachable (classic :22 + SMTP :25)
probe_denied_tcp 22
probe_denied_tcp 25

# 3) Random port outside the whitelist not reachable
random_denied_port() {
  local p
  local -a avoid=(22 25 80 443 465 587 "${PLATFORM_SSH_PORT}")
  local skip
  local a
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    p=$((10000 + RANDOM % 50000))
    skip=0
    for a in "${avoid[@]}"; do
      if [[ "${p}" -eq "${a}" ]]; then
        skip=1
        break
      fi
    done
    [[ "${skip}" -eq 0 ]] || continue
    printf '%s\n' "${p}"
    return 0
  done
  printf '34567\n'
}

RAND_PORT="$(random_denied_port)"
probe_denied_tcp "${RAND_PORT}"
