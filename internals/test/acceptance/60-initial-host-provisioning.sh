#!/usr/bin/env bash
# Acceptance Test: Initial Host Provisioning finished
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session

# IHP Done waits for Substrate without exposing delivery-adapter details on this
# Acceptance Test interface.
wait_until_ihp_done
pass "Initial Host Provisioning finished"
