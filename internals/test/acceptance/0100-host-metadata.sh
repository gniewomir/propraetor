#!/usr/bin/env bash
# Acceptance Test: Host metadata (name, region, size, image, Propraetor Tag, Role Tag)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

[[ -n "${HOST_JSON:-}" && "${HOST_JSON}" != "null" ]] || fail "fixture missing HOST_JSON (run via ./test.sh acceptance)"

HOST_NAME="propraetor-${PLATFORM_ENV}-web"
PROPRAETOR_TAG="propraetor-${PLATFORM_ENV}"
ROLE_TAG="propraetor-${PLATFORM_ENV}-public-web"

echo "${HOST_JSON}" | jq -e --arg name "${HOST_NAME}" '.name == $name' >/dev/null || fail "Host name != ${HOST_NAME}"
echo "${HOST_JSON}" | jq -e '.region.slug == "fra1"' >/dev/null || fail "Host region != fra1"
echo "${HOST_JSON}" | jq -e '.size_slug | type == "string" and length > 0' >/dev/null || fail "Host missing size_slug"
echo "${HOST_JSON}" | jq -e '.image.slug == "ubuntu-26-04-x64"' >/dev/null || fail "Host image mismatch"
echo "${HOST_JSON}" | jq -e --arg tag "${PROPRAETOR_TAG}" '.tags | index($tag) != null' >/dev/null \
  || fail "Host missing Propraetor Tag ${PROPRAETOR_TAG}"
echo "${HOST_JSON}" | jq -e --arg tag "${ROLE_TAG}" '.tags | index($tag) != null' >/dev/null \
  || fail "Host missing Role Tag ${ROLE_TAG}"
pass "Host metadata (name, region, size, image, Propraetor Tag, Role Tag)"
