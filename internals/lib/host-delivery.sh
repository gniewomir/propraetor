#!/usr/bin/env bash
# Host delivery on Host-session: ship a local stage directory to a Host path, then run a command.
# Sourced by operator entrypoints (Orphan Reap, Workload Setup, ensure-fabric, ensure-components). Requires ssh.sh.
# Public interface:
#   host_delivery_run STAGE REMOTE_ROOT REMOTE_CMD
#     Replace REMOTE_ROOT on the ambient Host-session with STAGE contents (ustar), then host_ssh REMOTE_CMD.

host_delivery_run() {
  local stage="${1:?host_delivery_run requires STAGE}"
  local remote_root="${2:?host_delivery_run requires REMOTE_ROOT}"
  local remote_cmd="${3:?host_delivery_run requires REMOTE_CMD}"

  [[ -d "${stage}" ]] || {
    echo "host_delivery_run: stage is not a directory: ${stage}" >&2
    return 1
  }
  [[ -n "${remote_root}" ]] || {
    echo "host_delivery_run: empty REMOTE_ROOT" >&2
    return 1
  }
  [[ -n "${remote_cmd}" ]] || {
    echo "host_delivery_run: empty REMOTE_CMD" >&2
    return 1
  }

  # COPYFILE_DISABLE: omit macOS AppleDouble xattrs from ustar (Host GNU tar rejects them).
  COPYFILE_DISABLE=1 tar --format=ustar -C "${stage}" -cf - . \
    | host_ssh "rm -rf ${remote_root} && mkdir -p ${remote_root} && tar -C ${remote_root} -xf -" \
    || return 1

  host_ssh "${remote_cmd}"
}
