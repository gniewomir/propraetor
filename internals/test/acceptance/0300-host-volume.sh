#!/usr/bin/env bash
# Acceptance Test: Host Volume size and attachment to the Host (ADR-0009)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

[[ -n "${HOST_JSON:-}" && "${HOST_JSON}" != "null" ]] || fail "fixture missing HOST_JSON (run via ./test.sh acceptance)"

VOLUME_NAME="propraetor-${PLATFORM_ENV}-web-data"
VOLUME_JSON="$(provider_host_volume_json)"
[[ -n "${VOLUME_JSON}" && "${VOLUME_JSON}" != "null" ]] \
  || fail "Host Volume ${VOLUME_NAME} not found at provider"

echo "${VOLUME_JSON}" | jq -e '.size_gigabytes == 1' >/dev/null || fail "Host Volume size != 1 GiB"
echo "${VOLUME_JSON}" | jq -e '.region.slug == "fra1"' >/dev/null || fail "Host Volume region != fra1"

HOST_ID="$(echo "${HOST_JSON}" | jq -r '.id | tostring')"
echo "${VOLUME_JSON}" | jq -e --argjson id "${HOST_ID}" '.droplet_ids | index($id) != null' >/dev/null \
  || fail "Host Volume not attached to provider Host ${HOST_ID}"

pass "Host Volume 1 GiB attached to Host"
