#!/usr/bin/env bash
# Host-local Workload materialize (ADR-0053 / #204).
# Shared by Mirror and singular Workload Setup — one projection rule.
#
# workload_materialize_tree ENV_TREE OUT
#   Build the Host Workload projection into OUT:
#   Environment tree upsert → resolve Manifest Source → apply Provides
#   directories (fail closed on reserved collisions). Manifest-less ENV_TREE
#   is bag upsert only. OUT is replaced.
#
# Internal Source paths are relative to ENV_TREE; zip paths to zip root
# (after optional sole-wrapper peel). After resolve, Artifact provides.json +
# requires.json are placed on OUT so Host shape matches (external ⊂ internal).
# Zip Environment trees must not already contain those contracts (fail closed
# before obtain). Path obtain keeps the `.zip` on OUT as Environment bag.

_MAT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Host Volume / stage ships copies of internals/lib/artifact/{source,provides}.sh
# beside this file. Unit Tests fall back to the in-tree Artifact libs.
_mat_source_lib="${_MAT_LIB_DIR}/source.sh"
if [[ ! -f "${_mat_source_lib}" ]]; then
  _mat_source_lib="${_MAT_LIB_DIR}/../../lib/artifact/source.sh"
fi
_mat_provides_lib="${_MAT_LIB_DIR}/provides.sh"
if [[ ! -f "${_mat_provides_lib}" ]]; then
  _mat_provides_lib="${_MAT_LIB_DIR}/../../lib/artifact/provides.sh"
fi
if [[ ! -f "${_mat_source_lib}" || ! -f "${_mat_provides_lib}" ]]; then
  echo "workload-materialize-host: Artifact Source/Provides libraries missing" >&2
  return 1
fi
# shellcheck source=../../lib/artifact/source.sh
source "${_mat_source_lib}"
# shellcheck source=../../lib/artifact/provides.sh
source "${_mat_provides_lib}"

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
  parent="$(dirname "${dest}")"
  mkdir -p "${parent}" || return 1
  rm -rf "${dest}"
  cp -a "${src}" "${dest}" || return 1
}

_workload_materialize_fetch_uri() {
  local uri="${1:?}"
  local extract_root="${2:?}"
  local zip_path

  command -v curl >/dev/null || {
    echo "workload_materialize_tree: curl required to fetch zip Source" >&2
    return 1
  }

  zip_path="$(umask 077; mktemp "${TMPDIR:-/tmp}/platform-wl-src.XXXXXX.zip")" || return 1
  if ! curl -fsSL --connect-timeout 30 --max-time 300 -o "${zip_path}" "${uri}"; then
    rm -f "${zip_path}"
    echo "workload_materialize_tree: failed to fetch Source zip: ${uri}" >&2
    return 1
  fi
  if ! artifact_source_zip_extract "${zip_path}" "${extract_root}"; then
    rm -f "${zip_path}"
    return 1
  fi
  rm -f "${zip_path}"
}

# ENV_TREE → OUT (Host Workload projection).
workload_materialize_tree() {
  local env_tree="${1:?workload_materialize_tree: Environment Workload tree required}"
  local out="${2:?workload_materialize_tree: output tree required}"
  local manifest wl_source wl_kind artifact_root extract_tmp provides requires dir_key

  [[ -d "${env_tree}" ]] || {
    echo "workload_materialize_tree: Environment tree missing: ${env_tree}" >&2
    return 1
  }

  artifact_source_tree_gate "${env_tree}" || return 1

  rm -rf "${out}"
  mkdir -p "${out}" || return 1
  cp -a "${env_tree}/." "${out}/" || return 1

  manifest="${out}/manifest.json"
  if [[ ! -f "${manifest}" ]]; then
    return 0
  fi

  wl_source="$(artifact_source_from_manifest "${manifest}")" || {
    echo "workload_materialize_tree: Source resolution failed for ${env_tree}" >&2
    return 1
  }
  wl_kind="$(artifact_source_kind "${wl_source}")" || return 1

  extract_tmp=""
  if [[ "${wl_kind}" == "internal" ]]; then
    artifact_root="${env_tree}"
  else
    extract_tmp="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/platform-wl-zip.XXXXXX")" || return 1
    if [[ "${wl_kind}" == "path" ]]; then
      if ! artifact_source_zip_extract "${env_tree}/${wl_source}" "${extract_tmp}"; then
        rm -rf "${extract_tmp}"
        return 1
      fi
    else
      if ! _workload_materialize_fetch_uri "${wl_source}" "${extract_tmp}"; then
        rm -rf "${extract_tmp}"
        return 1
      fi
    fi
    artifact_root="${extract_tmp}"
  fi

  provides="${artifact_root}/provides.json"
  requires="${artifact_root}/requires.json"
  if [[ ! -f "${provides}" ]]; then
    [[ -n "${extract_tmp}" ]] && rm -rf "${extract_tmp}"
    echo "workload_materialize_tree: Artifact provides.json missing under Source root" >&2
    return 1
  fi
  if [[ ! -f "${requires}" ]]; then
    [[ -n "${extract_tmp}" ]] && rm -rf "${extract_tmp}"
    echo "workload_materialize_tree: Artifact requires.json missing under Source root" >&2
    return 1
  fi

  if ! artifact_provides_reserved_collision "${out}" "${provides}"; then
    [[ -n "${extract_tmp}" ]] && rm -rf "${extract_tmp}"
    echo "workload_materialize_tree: reserved-file collision applying Provides directories" >&2
    return 1
  fi

  while IFS= read -r dir_key; do
    [[ -n "${dir_key}" ]] || continue
    if ! _workload_materialize_apply_directory "${artifact_root}" "${out}" "${dir_key}"; then
      [[ -n "${extract_tmp}" ]] && rm -rf "${extract_tmp}"
      return 1
    fi
  done < <(artifact_provides_directories "${provides}")

  cp -a "${provides}" "${out}/provides.json" || {
    [[ -n "${extract_tmp}" ]] && rm -rf "${extract_tmp}"
    return 1
  }
  cp -a "${requires}" "${out}/requires.json" || {
    [[ -n "${extract_tmp}" ]] && rm -rf "${extract_tmp}"
    return 1
  }

  [[ -n "${extract_tmp}" ]] && rm -rf "${extract_tmp}"
  return 0
}
