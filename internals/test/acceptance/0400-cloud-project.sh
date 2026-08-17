#!/usr/bin/env bash
# Acceptance Test: Cloud Project Propraetor owns the Host, Host Volume, and Reserved IP
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

[[ -n "${HOST_JSON:-}" && "${HOST_JSON}" != "null" ]] || fail "fixture missing HOST_JSON (run via ./test.sh acceptance)"

PROJECT_NAME="propraetor-${PLATFORM_ENV}"
PROJECT_JSON="$(provider_cloud_project_json)"
[[ -n "${PROJECT_JSON}" && "${PROJECT_JSON}" != "null" ]] \
  || fail "Cloud Project ${PROJECT_NAME} not found at provider"
echo "${PROJECT_JSON}" | jq -e '.environment == "Production"' >/dev/null || fail "Cloud Project environment != Production"
echo "${PROJECT_JSON}" | jq -e '.is_default == false' >/dev/null || fail "Cloud Project must not be account default"

PROJECT_ID="$(echo "${PROJECT_JSON}" | jq -r '.id')"
PROJECT_RESOURCES="$(do_api_get "/v2/projects/${PROJECT_ID}/resources?per_page=200")"

HOST_ID="$(echo "${HOST_JSON}" | jq -r '.id | tostring')"
[[ -n "${HOST_ID}" && "${HOST_ID}" != "null" ]] || fail "Host id missing from provider fixture"
HOST_URN="do:droplet:${HOST_ID}"
echo "${PROJECT_RESOURCES}" | jq -e --arg urn "${HOST_URN}" \
  '[.resources[].urn] | index($urn) != null' >/dev/null \
  || fail "Host URN not assigned to Cloud Project ${PROJECT_NAME}"

VOLUME_NAME="propraetor-${PLATFORM_ENV}-web-data"
VOLUME_ID="$(provider_host_volume_json | jq -r '.id // empty')"
[[ -n "${VOLUME_ID}" ]] || fail "Host Volume ${VOLUME_NAME} not found at provider"
VOLUME_URN="do:volume:${VOLUME_ID}"
echo "${PROJECT_RESOURCES}" | jq -e --arg urn "${VOLUME_URN}" \
  '[.resources[].urn] | index($urn) != null' >/dev/null \
  || fail "Host Volume URN not assigned to Cloud Project ${PROJECT_NAME}"

# Projects list and Durable assignment both use do:reservedip:<ip>.
RESERVED_URN="do:reservedip:${IP}"
echo "${PROJECT_RESOURCES}" | jq -e --arg urn "${RESERVED_URN}" \
  '[.resources[].urn] | index($urn) != null' >/dev/null \
  || fail "Reserved IP not assigned to Cloud Project ${PROJECT_NAME}"

while IFS= read -r zone; do
  [[ -n "${zone}" ]] || continue
  DOMAIN_URN="do:domain:${zone}"
  echo "${PROJECT_RESOURCES}" | jq -e --arg urn "${DOMAIN_URN}" \
    '[.resources[].urn] | index($urn) != null' >/dev/null \
    || fail "Domain ${zone} not assigned to Cloud Project ${PROJECT_NAME}"
done < <(configured_domain_names)

pass "Cloud Project owns configured Durable and Recreatable memberships"
