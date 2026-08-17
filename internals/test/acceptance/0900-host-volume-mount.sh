#!/usr/bin/env bash
# Acceptance Test: Host Volume mounted at /host-volume (ADR-0009 / ADR-0054)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session

# Standalone runs may skip 60-*; IHP Done gate waits so findmnt sees post-IHP mount.
wait_until_ihp_done

# findmnt MOUNTPOINT (not -T): -T follows the path and can match / if unmounted.
if ! host_ssh "findmnt --mountpoint /host-volume" >/dev/null 2>&1; then
  fail "/host-volume is not a mounted filesystem"
fi

owner="$(host_ssh "stat -c '%U:%G' /host-volume" 2>/dev/null || true)"
if [[ "${owner}" != "root:root" ]]; then
  fail "/host-volume owner expected root:root, got '${owner}'"
fi

pass "Host Volume mounted at /host-volume"
