#!/usr/bin/env bash
# Unified systemd/ unit bag helpers (sourced by Component and Workload Host libs).
# One bag per owner: Quadlet sources + native units under systemd/ (ADR-0054).
# Install: Quadlets via kind-prefixed directory symlink farm under UNIT_DIR;
# natives copy into SYSTEMD_USER_DIR. Retired consumer dir quadlets/ fails closed.

# True when extension is a Quadlet unit source.
unit_ext_is_quadlet() {
  case "$1" in
  container | pod | kube | network | volume | image | build | artifact) return 0 ;;
  *) return 1 ;;
  esac
}

# True when extension is a native systemd unit.
unit_ext_is_native() {
  case "$1" in
  service | timer | socket | path | target | slice | mount | automount | swap) return 0 ;;
  *) return 1 ;;
  esac
}

# True when extension is allowlisted in the unified systemd/ bag.
unit_ext_is_allowlisted() {
  unit_ext_is_quadlet "$1" || unit_ext_is_native "$1"
}

# Kind-prefixed Quadlet farm directory name under UNIT_DIR (XDG, not Host Volume).
# Args: kind (workload|component|fabric) [id]  — fabric needs no id.
unit_quadlet_farm_id() {
  local kind="${1:?unit_quadlet_farm_id: kind required}"
  local id="${2:-}"
  case "${kind}" in
  workload)
    [[ -n "${id}" ]] || {
      echo "unit_quadlet_farm_id: workload id required" >&2
      return 1
    }
    printf 'workload-%s\n' "${id}"
    ;;
  component)
    [[ -n "${id}" ]] || {
      echo "unit_quadlet_farm_id: component id required" >&2
      return 1
    }
    printf 'component-%s\n' "${id}"
    ;;
  fabric)
    printf 'fabric\n'
    ;;
  *)
    echo "unit_quadlet_farm_id: unknown kind '${kind}'" >&2
    return 1
    ;;
  esac
}

# Absolute path of the farm entry under UNIT_DIR.
# Args: kind id(optional for fabric)
unit_quadlet_farm_path() {
  local farm_id
  farm_id="$(unit_quadlet_farm_id "$@")" || return 1
  printf '%s/%s\n' "${UNIT_DIR}" "${farm_id}"
}

# List regular non-hidden basenames in a unit bag directory (may be missing).
unit_bag_basenames() {
  local bag_dir="${1:-}"
  local f base
  [[ -n "${bag_dir}" && -d "${bag_dir}" ]] || return 0
  for f in "${bag_dir}"/*; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    [[ "${base}" == .* ]] && continue
    printf '%s\n' "${base}"
  done
}

# Count allowlisted unit files in bag_dir (0 if missing).
unit_bag_allowlisted_count() {
  local bag_dir="${1:-}"
  local base ext count=0
  while IFS= read -r base; do
    [[ -n "${base}" ]] || continue
    ext="${base##*.}"
    if unit_ext_is_allowlisted "${ext}"; then
      count=$((count + 1))
    fi
  done < <(unit_bag_basenames "${bag_dir}")
  printf '%s\n' "${count}"
}

# Fail closed if retired quadlets/ consumer dir is present on a tree.
# Args: tree_dir label
unit_refuse_retired_quadlets_dir() {
  local tree_dir="${1:?}"
  local label="${2:-tree}"
  if [[ -e "${tree_dir}/quadlets" || -L "${tree_dir}/quadlets" ]]; then
    echo "unit ${label}: retired consumer directory quadlets/ must not be present (use systemd/)" >&2
    return 1
  fi
}

# Fail closed if any regular file in bag_dir has an unsupported extension.
# Args: bag_dir (may be missing — caller enforces ≥1 separately)
unit_validate_systemd_bag() {
  local bag_dir="${1:-}"
  local f base ext
  [[ -n "${bag_dir}" && -d "${bag_dir}" ]] || return 0
  for f in "${bag_dir}"/*; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    [[ "${base}" == .* ]] && continue
    ext="${base##*.}"
    if [[ "${base}" == "${ext}" ]]; then
      echo "unit systemd/ file '${base}' has no extension (invalid unit)" >&2
      return 1
    fi
    if unit_ext_is_allowlisted "${ext}"; then
      continue
    fi
    echo "unit systemd/ file '${base}' has unsupported extension '.${ext}'" >&2
    return 1
  done
}

# Fail closed unless bag_dir contains ≥1 allowlisted unit file.
# Args: bag_dir label
unit_require_systemd_bag_nonempty() {
  local bag_dir="${1:-}"
  local label="${2:-owner}"
  local count
  if [[ -z "${bag_dir}" || ! -d "${bag_dir}" ]]; then
    echo "unit ${label}: systemd/ bag missing (need ≥1 allowlisted unit)" >&2
    return 1
  fi
  count="$(unit_bag_allowlisted_count "${bag_dir}")"
  if [[ "${count}" -lt 1 ]]; then
    echo "unit ${label}: systemd/ bag empty (need ≥1 allowlisted unit)" >&2
    return 1
  fi
}

# True when basename exists as a native unit or under any Quadlet farm entry.
unit_basename_exists_on_host() {
  local base="$1"
  local entry
  [[ -e "${SYSTEMD_USER_DIR}/${base}" ]] && return 0
  [[ -e "${UNIT_DIR}/${base}" ]] && return 0
  for entry in "${UNIT_DIR}"/*; do
    [[ -e "${entry}" ]] || continue
    if [[ -e "${entry}/${base}" ]]; then
      return 0
    fi
  done
  return 1
}
