#!/usr/bin/env bash
# Environment Workload discovery (ADR-0047; amends ADR-0041 / #156).
# Discovers Workload directories under an Environment as every immediate non-hidden
# child directory (ADR-0033). Does not require or validate manifest.json.
#
# Public interface:
#   environment_discover_workloads ENV_DIR
#     Prints sorted basenames (one per line). Empty when none.

environment_discover_workloads() {
  local env_dir="${1:?environment_discover_workloads requires ENV_DIR}"
  local child name

  [[ -d "${env_dir}" ]] || {
    echo "environment_discover_workloads: not a directory: ${env_dir}" >&2
    return 1
  }

  for child in "${env_dir}"/*; do
    [[ -d "${child}" ]] || continue
    name="$(basename "${child}")"
    [[ "${name}" != .* ]] || continue
    printf '%s\n' "${name}"
  done | LC_ALL=C sort
}
