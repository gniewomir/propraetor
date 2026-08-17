#!/usr/bin/env bash
# Acceptance Test: rootless Platform User exists with linger
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session

USER_NAME="${PLATFORM_USER:-platform}"

# Standalone runs may race IHP; gate then assert linger (beyond IHP Done id check).
wait_until_ihp_done

if ! host_ssh "id '${USER_NAME}'" >/dev/null 2>&1; then
  fail "Platform User '${USER_NAME}' missing on Host"
fi

if ! linger="$(host_ssh "loginctl show-user '${USER_NAME}' -p Linger --value" 2>/dev/null)"; then
  fail "loginctl show-user ${USER_NAME} failed on Host"
fi

if [[ "${linger}" == "yes" ]]; then
  pass "Platform User ${USER_NAME} exists with linger"
else
  fail "Platform User ${USER_NAME} linger: expected yes, got '${linger}'"
fi
