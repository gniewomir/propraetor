#!/usr/bin/env bash
# Operator-side IHP Done helpers (ADR-0030 cutover reboot race).
# Sourced by ensure-fabric, ensure-components, and Acceptance — requires ambient Host-session (host_ssh).

# Run Host-local wait-until-ihp-done over SSH. Retries when SSH exits 255 (connection
# drop during ADR-0030 power_state reboot). Non-255 failures fail closed immediately.
# Usage: host_wait_until_ihp_done <wait-script-path> [platform-user]
# Optional: IHP_DONE_TIMEOUT_SECONDS (default 600), IHP_DONE_RETRY_SECONDS (default 5)
host_wait_until_ihp_done() {
  local script="${1:?host_wait_until_ihp_done requires wait-until-ihp-done.sh path}"
  local user="${2:-platform}"
  local timeout="${IHP_DONE_TIMEOUT_SECONDS:-600}"
  local retry_sleep="${IHP_DONE_RETRY_SECONDS:-5}"
  local deadline=$((SECONDS + timeout))
  local rc=0
  local paths_lib

  [[ -f "${script}" ]] || {
    echo "missing ${script}" >&2
    return 1
  }

  # bash -s leaves BASH_SOURCE unbound (set -u) and has no script dir, so the
  # wait script cannot source siblings. Prepend Host Volume path helpers.
  paths_lib="$(cd "$(dirname "${script}")" && pwd)/lib/host-volume-paths-host.sh"
  [[ -f "${paths_lib}" ]] || {
    echo "missing ${paths_lib}" >&2
    return 1
  }

  while true; do
    rc=0
    # Process substitution: one stdin stream of lib + gate for remote bash -s.
    host_ssh "PLATFORM_USER=${user} bash -s" < <(cat -- "${paths_lib}" "${script}") || rc=$?
    if [[ ${rc} -eq 0 ]]; then
      return 0
    fi
    # ssh(1): 255 = connection/protocol error (reboot reset, timeout). Script
    # failures propagate as the remote exit status (typically 1).
    if [[ ${rc} -ne 255 ]]; then
      return "${rc}"
    fi
    if ((SECONDS >= deadline)); then
      echo "IHP Done not reached within ${timeout}s (last SSH exit ${rc})" >&2
      return 1
    fi
    echo "IHP Done wait interrupted (often ADR-0030 reboot); retrying SSH ..." >&2
    sleep "${retry_sleep}"
  done
}
