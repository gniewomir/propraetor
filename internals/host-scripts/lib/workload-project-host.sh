#!/usr/bin/env bash
# Host Workload projection (ADR-0054 / #228).
# One outcome: Environment tree → Host Volume owner tree with Persist preserved.
#
# workload_project_to_host ENV_TREE DEST
#   Materialize ENV_TREE, sync into DEST in place (never replace Persist), and
#   ensure DEST/persist exists (empty when missing). Mirror and Workload Setup
#   share this seam so Persist refuse / skip / mkdir are not relearned per caller.

_PROJ_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workload-materialize-host.sh
source "${_PROJ_LIB_DIR}/workload-materialize-host.sh"
# shellcheck source=sync-tree-host.sh
source "${_PROJ_LIB_DIR}/sync-tree-host.sh"

# ENV_TREE → DEST (Host Volume owner tree). Persist under DEST survives replace.
workload_project_to_host() {
  local env_tree="${1:?workload_project_to_host: Environment Workload tree required}"
  local dest="${2:?workload_project_to_host: Host Volume owner tree required}"
  local mat_tmp

  [[ -d "${env_tree}" ]] || {
    echo "workload_project_to_host: Environment tree missing: ${env_tree}" >&2
    return 1
  }

  mat_tmp="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/platform-wl-project.XXXXXX")" || return 1
  if ! workload_materialize_tree "${env_tree}" "${mat_tmp}"; then
    rm -rf "${mat_tmp}"
    return 1
  fi
  if ! sync_tree_inplace "${mat_tmp}" "${dest}"; then
    rm -rf "${mat_tmp}"
    return 1
  fi
  rm -rf "${mat_tmp}"

  mkdir -p "${dest}/persist" || return 1
  return 0
}
