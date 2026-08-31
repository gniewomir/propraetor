#!/usr/bin/env bash
# Host-local Workload materialize (ADR-0053 / ADR-0059 / #204 / #262).
# Shared by Mirror and singular Workload Setup — one projection rule.
#
# workload_materialize_tree ENV_TREE OUT
#   Build the Host Workload projection into OUT:
#   Environment tree upsert → read Artifact staging → ship staged zip →
#   extract (ADR-0053 peel) → land Artifact root via Provides directories
#   (fail closed on reserved collisions). Manifest-less ENV_TREE is bag
#   upsert only. OUT is replaced. Symlink + Environment contract gates run
#   on ENV_TREE; path zip file gate is skipped (Host zip is staging-only).
#
# Staging resolves from ENVIRONMENT_ROOT/.artifact-cache/<basename>.staging
# where ENVIRONMENT_ROOT=$(dirname ENV_TREE) and basename=$(basename ENV_TREE).
# After extract, Artifact provides.json + requires.json are placed on OUT so
# Host shape matches (external ⊂ internal). Zip/git/local Environment trees
# must not already contain those contracts (fail closed before staging read).

_MAT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Host Volume / stage ships copies of internals/lib/artifact/{source,provides,staging}.sh
# beside this file. Unit Tests fall back to the in-tree Artifact libs.
_mat_source_lib="${_MAT_LIB_DIR}/source.sh"
if [[ ! -f "${_mat_source_lib}" ]]; then
  _mat_source_lib="${_MAT_LIB_DIR}/../../lib/artifact/source.sh"
fi
_mat_provides_lib="${_MAT_LIB_DIR}/provides.sh"
if [[ ! -f "${_mat_provides_lib}" ]]; then
  _mat_provides_lib="${_MAT_LIB_DIR}/../../lib/artifact/provides.sh"
fi
_mat_staging_lib="${_MAT_LIB_DIR}/staging.sh"
if [[ ! -f "${_mat_staging_lib}" ]]; then
  _mat_staging_lib="${_MAT_LIB_DIR}/../../lib/artifact/staging.sh"
fi
if [[ ! -f "${_mat_source_lib}" || ! -f "${_mat_provides_lib}" || ! -f "${_mat_staging_lib}" ]]; then
  echo "workload-materialize-host: Artifact Source/Provides/Staging libraries missing" >&2
  return 1
fi
# shellcheck source=../../lib/artifact/source.sh
source "${_mat_source_lib}"
# shellcheck source=../../lib/artifact/provides.sh
source "${_mat_provides_lib}"
# shellcheck source=../../lib/artifact/staging.sh
source "${_mat_staging_lib}"
# shellcheck source=unit-consumers-host.sh
source "${_MAT_LIB_DIR}/unit-consumers-host.sh"

_workload_materialize_normalize_rel() {
  local key="${1:?}"
  local rel="${key#./}"
  local part
  if [[ "${rel}" == "." || -z "${rel}" ]]; then
    printf '%s\n' "."
    return 0
  fi
  if [[ "${rel}" == /* ]]; then
    echo "workload_materialize_tree: Provides directories path not allowed: ${key}" >&2
    return 1
  fi
  while IFS= read -r -d '/' part || [[ -n "${part}" ]]; do
    if [[ "${part}" == ".." ]]; then
      echo "workload_materialize_tree: Provides directories path not allowed: ${key}" >&2
      return 1
    fi
  done <<<"${rel}/"
  printf '%s\n' "${rel}"
}

_workload_materialize_apply_directory() {
  local artifact_root="${1:?}"
  local out="${2:?}"
  local key="${3:?}"
  local rel src dest parent

  rel="$(_workload_materialize_normalize_rel "${key}")" || return 1
  if [[ "${rel}" == "." ]]; then
    cp -a "${artifact_root}/." "${out}/" || return 1
    return 0
  fi

  src="${artifact_root}/${rel}"
  dest="${out}/${rel}"
  if [[ ! -e "${src}" && ! -L "${src}" ]]; then
    echo "workload_materialize_tree: Provides directories missing in Artifact: ${key}" >&2
    return 1
  fi

  # Unified systemd/ bag: merge by filename; same name from both sides fails closed.
  if [[ "${rel}" == "systemd" ]]; then
    _workload_materialize_merge_systemd_bag "${src}" "${dest}" || return 1
    return 0
  fi

  parent="$(dirname "${dest}")"
  mkdir -p "${parent}" || return 1
  rm -rf "${dest}"
  cp -a "${src}" "${dest}" || return 1
}

# Merge Artifact systemd/ into Environment systemd/ by filename (ADR-0054).
# Args: artifact_systemd_dir dest_systemd_dir
_workload_materialize_merge_systemd_bag() {
  local src="${1:?}"
  local dest="${2:?}"
  local f base

  [[ -d "${src}" ]] || {
    echo "workload_materialize_tree: Provides systemd/ is not a directory" >&2
    return 1
  }
  mkdir -p "${dest}" || return 1
  for f in "${src}"/*; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    [[ "${base}" == .* ]] && continue
    if [[ -e "${dest}/${base}" || -L "${dest}/${base}" ]]; then
      echo "workload_materialize_tree: systemd/ filename collision: ${base}" >&2
      return 1
    fi
    install -m 0644 "${f}" "${dest}/${base}" || return 1
  done
}

_workload_materialize_refuse_quadlets() {
  local tree="${1:?}"
  local label="${2:?}"
  if [[ -e "${tree}/quadlets" || -L "${tree}/quadlets" ]]; then
    echo "workload_materialize_tree: ${label} must not ship retired quadlets/ (use systemd/)" >&2
    return 1
  fi
}

_workload_materialize_require_systemd_bag() {
  local tree="${1:?}"
  unit_refuse_retired_quadlets_dir "${tree}" "materialized tree" || return 1
  unit_validate_systemd_bag "${tree}/systemd" || return 1
  unit_require_systemd_bag_nonempty "${tree}/systemd" "materialized Workload" || return 1
}

_workload_materialize_refuse_persist() {
  local tree="${1:?}"
  local label="${2:?}"
  if [[ -e "${tree}/persist" || -L "${tree}/persist" ]]; then
    echo "workload_materialize_tree: ${label} must not ship persist/ (reserved Persist)" >&2
    return 1
  fi
}

# ENV_TREE → OUT (Host Workload projection).
workload_materialize_tree() {
  local env_tree="${1:?workload_materialize_tree: Environment Workload tree required}"
  local out="${2:?workload_materialize_tree: output tree required}"
  local environment_root wl_basename staged_zip_path zip_basename extract_tmp
  local artifact_root provides requires dir_key manifest

  [[ -d "${env_tree}" ]] || {
    echo "workload_materialize_tree: Environment tree missing: ${env_tree}" >&2
    return 1
  }

  artifact_source_symlink_gate "${env_tree}" || return 1
  artifact_source_environment_tree_gate "${env_tree}" || return 1
  _workload_materialize_refuse_persist "${env_tree}" "Environment tree" || return 1
  _workload_materialize_refuse_quadlets "${env_tree}" "Environment tree" || return 1

  rm -rf "${out}"
  mkdir -p "${out}" || return 1
  cp -a "${env_tree}/." "${out}/" || return 1

  manifest="${out}/manifest.json"
  if [[ ! -f "${manifest}" ]]; then
    return 0
  fi

  environment_root="$(dirname "${env_tree}")"
  wl_basename="$(basename "${env_tree}")"
  staged_zip_path="$(artifact_staging_read "${environment_root}" "${wl_basename}")" || return 1

  zip_basename="$(basename "${staged_zip_path}")"
  cp -a "${staged_zip_path}" "${out}/${zip_basename}" || return 1

  extract_tmp="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/platform-wl-staging.XXXXXX")" || return 1
  if ! artifact_source_zip_extract "${staged_zip_path}" "${extract_tmp}"; then
    rm -rf "${extract_tmp}"
    return 1
  fi
  artifact_root="${extract_tmp}"

  if ! _workload_materialize_refuse_persist "${artifact_root}" "Artifact"; then
    rm -rf "${extract_tmp}"
    return 1
  fi
  if ! _workload_materialize_refuse_quadlets "${artifact_root}" "Artifact"; then
    rm -rf "${extract_tmp}"
    return 1
  fi

  provides="${artifact_root}/provides.json"
  requires="${artifact_root}/requires.json"
  if [[ ! -f "${provides}" ]]; then
    rm -rf "${extract_tmp}"
    echo "workload_materialize_tree: Artifact provides.json missing under staged zip" >&2
    return 1
  fi
  if [[ ! -f "${requires}" ]]; then
    rm -rf "${extract_tmp}"
    echo "workload_materialize_tree: Artifact requires.json missing under staged zip" >&2
    return 1
  fi

  if ! artifact_provides_reserved_collision "${out}" "${provides}"; then
    rm -rf "${extract_tmp}"
    echo "workload_materialize_tree: reserved-file collision applying Provides directories" >&2
    return 1
  fi

  while IFS= read -r dir_key; do
    [[ -n "${dir_key}" ]] || continue
    if ! _workload_materialize_apply_directory "${artifact_root}" "${out}" "${dir_key}"; then
      rm -rf "${extract_tmp}"
      return 1
    fi
  done < <(artifact_provides_directories "${provides}")

  cp -a "${provides}" "${out}/provides.json" || {
    rm -rf "${extract_tmp}"
    return 1
  }
  cp -a "${requires}" "${out}/requires.json" || {
    rm -rf "${extract_tmp}"
    return 1
  }

  if ! _workload_materialize_refuse_persist "${out}" "materialized tree"; then
    rm -rf "${extract_tmp}"
    return 1
  fi
  if ! _workload_materialize_require_systemd_bag "${out}"; then
    rm -rf "${extract_tmp}"
    return 1
  fi

  rm -rf "${extract_tmp}"
  return 0
}
