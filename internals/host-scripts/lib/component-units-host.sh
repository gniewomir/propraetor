#!/usr/bin/env bash
# Component / Fabric unified systemd/ unit install (sourced by Component Setup).
# Quadlets: kind-prefixed directory symlink under UNIT_DIR → tree/systemd/.
# Natives: copy into SYSTEMD_USER_DIR. Retired quadlets/ fails closed (ADR-0054).
#
# Expects after quadlet_user_session_begin: UNIT_DIR, SYSTEMD_USER_DIR.
# Optional: USER_NAME for soft-fail chown (offline tests / non-root).

# shellcheck source=unit-consumers-host.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/unit-consumers-host.sh"

# Copy native units from bag into SYSTEMD_USER_DIR; leave Quadlet sources alone.
# Args: bag_dir
component_units_install_natives() {
  local bag_dir="${1:-}"
  local src base ext
  mkdir -p "${SYSTEMD_USER_DIR}"
  [[ -n "${bag_dir}" && -d "${bag_dir}" ]] || return 0
  for src in "${bag_dir}"/*; do
    [[ -f "${src}" ]] || continue
    base="$(basename "${src}")"
    [[ "${base}" == .* ]] && continue
    ext="${base##*.}"
    unit_ext_is_native "${ext}" || continue
    install -m 0644 "${src}" "${SYSTEMD_USER_DIR}/${base}"
    if [[ -n "${USER_NAME:-}" ]]; then
      chown "${USER_NAME}:${USER_NAME}" "${SYSTEMD_USER_DIR}/${base}" 2>/dev/null || true
    fi
  done
}

# Ensure UNIT_DIR/<farm-id> is a directory symlink to bag_dir (never a file symlink).
# Args: kind id(optional) bag_dir
component_units_install_quadlet_farm() {
  local kind="${1:?}"
  local id="${2:-}"
  local bag_dir="${3:?}"
  local farm_path farm_id

  if [[ "${kind}" == "fabric" ]]; then
    farm_id="$(unit_quadlet_farm_id fabric)" || return 1
  else
    farm_id="$(unit_quadlet_farm_id "${kind}" "${id}")" || return 1
  fi
  farm_path="${UNIT_DIR}/${farm_id}"
  mkdir -p "${UNIT_DIR}"

  if [[ -L "${farm_path}" ]]; then
    rm -f "${farm_path}"
  elif [[ -e "${farm_path}" ]]; then
    echo "component_units_install: farm path '${farm_path}' exists and is not a symlink" >&2
    return 1
  fi

  # Directory symlink only — never ln -s onto a unit file basename.
  if [[ ! -d "${bag_dir}" ]]; then
    echo "component_units_install: systemd bag missing for farm '${farm_id}'" >&2
    return 1
  fi
  ln -s "${bag_dir}" "${farm_path}" || return 1
  if [[ -n "${USER_NAME:-}" ]]; then
    chown -h "${USER_NAME}:${USER_NAME}" "${farm_path}" 2>/dev/null || true
  fi
}

# Validate + install unified systemd/ bag from a Component/Fabric tree.
# Args: tree kind id
#   kind=fabric → id ignored; farm id "fabric"
#   kind=component → id is Component name
component_units_install() {
  local tree="${1:?component tree required}"
  local kind="${2:?kind required (component|fabric)}"
  local id="${3:-}"
  local bag="${tree}/systemd"

  unit_refuse_retired_quadlets_dir "${tree}" "${kind}" || return 1
  unit_validate_systemd_bag "${bag}" || return 1
  unit_require_systemd_bag_nonempty "${bag}" "${kind}" || return 1

  case "${kind}" in
  fabric)
    component_units_install_quadlet_farm fabric "" "${bag}" || return 1
    ;;
  component)
    [[ -n "${id}" ]] || {
      echo "component_units_install: component id required" >&2
      return 1
    }
    component_units_install_quadlet_farm component "${id}" "${bag}" || return 1
    ;;
  *)
    echo "component_units_install: unknown kind '${kind}'" >&2
    return 1
    ;;
  esac
  component_units_install_natives "${bag}" || return 1
}
