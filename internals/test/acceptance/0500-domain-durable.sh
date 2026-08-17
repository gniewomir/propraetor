#!/usr/bin/env bash
# Acceptance Test: Domain Durables in Applied State (ADR-0020)
# Empty Domain config is valid. When configured, every provider zone exists and
# each Stack-authored A record points at the Reserved IP. Does not Park or Teardown.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
DOMAINS_PATH="$(environment_domains_path)"
if [[ ! -f "${DOMAINS_PATH}" ]] || [[ "$(jq 'length' "${DOMAINS_PATH}")" -eq 0 ]]; then
  pass "Domain Durables absent (0 Domains configured)"
  exit 0
fi

while IFS= read -r zone; do
  [[ -n "${zone}" ]] || continue
  do_api_get "/v2/domains/${zone}" >/dev/null \
    || fail "Domain ${zone} not found at provider"
  RECORDS_JSON="$(do_api_get "/v2/domains/${zone}/records?per_page=200")"
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    echo "${RECORDS_JSON}" | jq -e --arg name "${name}" --arg ip "${IP}" \
      '[.domain_records[] | select(.type == "A" and .name == $name and .data == $ip)] | length == 1' \
      >/dev/null \
      || fail "Domain ${zone} record ${name} is not exactly one A → ${IP}"
  done < <(jq -r --arg zone "${zone}" '.[$zone].names[]' "${DOMAINS_PATH}")
done < <(configured_domain_names)

pass "configured Domain Durables and A records → Reserved IP"
