#!/usr/bin/env bash
# Ship inventory for Host Workload projection (Mirror + Workload Setup share).
# Operator-side staging only — not sourced on the Host.
#
# Public interface:
#   workload_project_stage_ship_inventory DEST_DIR
#     Copy projection libs into DEST_DIR (flat). Mirror stages into STAGE/lib;
#     Workload Setup stages into STAGE root. One inventory so Mirror vs Setup
#     cannot drift on what the projected tree needs (#233 / #228).

_WL_PROJ_SHIP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WL_PROJ_SHIP_REPO="$(cd "${_WL_PROJ_SHIP_DIR}/../../.." && pwd)"
_WL_PROJ_SHIP_HOST_LIB="${_WL_PROJ_SHIP_REPO}/internals/host-scripts/lib"
_WL_PROJ_SHIP_ARTIFACT="${_WL_PROJ_SHIP_REPO}/internals/lib/artifact"

workload_project_stage_ship_inventory() {
  local dest="${1:?workload_project_stage_ship_inventory: DEST_DIR required}"

  mkdir -p "${dest}" || return 1
  cp "${_WL_PROJ_SHIP_HOST_LIB}/sync-tree-host.sh" "${dest}/sync-tree-host.sh" || return 1
  cp "${_WL_PROJ_SHIP_HOST_LIB}/workload-materialize-host.sh" \
    "${dest}/workload-materialize-host.sh" || return 1
  cp "${_WL_PROJ_SHIP_HOST_LIB}/workload-project-host.sh" \
    "${dest}/workload-project-host.sh" || return 1
  cp "${_WL_PROJ_SHIP_HOST_LIB}/unit-consumers-host.sh" \
    "${dest}/unit-consumers-host.sh" || return 1
  cp "${_WL_PROJ_SHIP_HOST_LIB}/host-volume-paths-host.sh" \
    "${dest}/host-volume-paths-host.sh" || return 1
  cp "${_WL_PROJ_SHIP_ARTIFACT}/source.sh" "${dest}/source.sh" || return 1
  cp "${_WL_PROJ_SHIP_ARTIFACT}/provides.sh" "${dest}/provides.sh" || return 1
  return 0
}
