#!/usr/bin/env bash
# Acceptance Test: Reserved IP assigned and matches Stack output
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
[[ -n "${RESERVED_IP_JSON:-}" && "${RESERVED_IP_JSON}" != "null" ]] \
  || fail "fixture missing RESERVED_IP_JSON (run via ./test.sh acceptance)"

ASSIGNED="$(echo "${RESERVED_IP_JSON}" | jq -r '.ip')"
[[ "${ASSIGNED}" == "${IP}" ]] || fail "Reserved IP output ${IP} != provider ${ASSIGNED}"
echo "${RESERVED_IP_JSON}" | jq -e '.droplet.id != null' >/dev/null \
  || fail "Reserved IP ${IP} is not assigned to a Host"
pass "Reserved IP assigned and exported"
