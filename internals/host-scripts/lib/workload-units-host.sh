#!/usr/bin/env bash
# Workload unified systemd/ unit apply (sourced by Workload Setup).
# Validates staged bag, syncs Host Volume SoT, reconciles farm + natives,
# optional before-reload hook, session reload, then applies Workload Intent.
#
# Public interface:
#   workload_units_preflight wl_name systemd_stage
#   workload_units_apply wl_name intent systemd_stage
#   workload_units_purge wl_name
#
# Optional ambient hook (caller-defined, unset after use):
#   workload_units_before_reload  — runs after reconcile, before daemon-reload
#                                   (Setup uses this for Environment Configuration)
#
# Requires ambient: WORKLOADS_ROOT, UNIT_DIR, SYSTEMD_USER_DIR, USER_NAME
# Assumes quadlet_user_session_begin already called (or dirs set for offline tests).

# shellcheck source=workload-quadlets-host.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workload-quadlets-host.sh"

# Collect native basenames currently in a bag (or empty if missing).
_workload_units_native_basenames() {
  local bag="${1:-}"
  local base ext
  while IFS= read -r base; do
    [[ -n "${base}" ]] || continue
    ext="${base##*.}"
    unit_ext_is_native "${ext}" || continue
    printf '%s\n' "${base}"
  done < <(unit_bag_basenames "${bag}")
}

# Fail closed on retired quadlets/, bad extensions, empty bag, foreign ownership.
# Does not mutate Host Volume SoT or Host unit dirs — call before other Setup writes.
# Args: wl_name systemd_stage
workload_units_preflight() {
  local wl_name="${1:?workload name required}"
  local systemd_stage="${2:-}"
  local prev_owned stage_units
  local base
  local rc=0
  local tree_hint="${WORKLOADS_ROOT}/${wl_name}"

  # Staged tree root is the parent of systemd_stage when present.
  if [[ -n "${systemd_stage}" ]]; then
    unit_refuse_retired_quadlets_dir "$(dirname "${systemd_stage}")" "Workload '${wl_name}' stage" || return 1
  fi
  if [[ -d "${tree_hint}" ]]; then
    unit_refuse_retired_quadlets_dir "${tree_hint}" "Workload '${wl_name}'" || return 1
  fi

  prev_owned="$(mktemp "${TMPDIR:-/tmp}/platform-prev-owned.XXXXXX")"
  stage_units="$(mktemp "${TMPDIR:-/tmp}/platform-stage-units.XXXXXX")"

  unit_bag_basenames "${WORKLOADS_ROOT}/${wl_name}/systemd" >"${prev_owned}" || true

  if ! unit_validate_systemd_bag "${systemd_stage}"; then
    rc=1
  elif ! unit_require_systemd_bag_nonempty "${systemd_stage}" "Workload '${wl_name}'"; then
    rc=1
  else
    unit_bag_basenames "${systemd_stage}" >"${stage_units}"

    while IFS= read -r base; do
      [[ -n "${base}" ]] || continue
      if ! workload_unit_refuse_foreign_basename "${wl_name}" "${base}" "${prev_owned}"; then
        rc=1
        break
      fi
    done <"${stage_units}"
  fi

  rm -f "${prev_owned}" "${stage_units}"
  return "${rc}"
}

# Apply unified bag from staged dir through Workload Intent.
# Args: wl_name intent systemd_stage
# Performs: preflight → sync SoT → reconcile → optional before_reload
#           hook → reload → Intent.
# Returns 0 on success.
workload_units_apply() {
  local wl_name="${1:?workload name required}"
  local intent="${2:?intent required}"
  local systemd_stage="${3:-}"
  local prev_owned prev_natives
  local rc=0

  case "${intent}" in
  run | stop | trash) ;;
  *)
    echo "workload_units_apply: intent must be run|stop|trash (got '${intent}')" >&2
    return 1
    ;;
  esac

  workload_units_preflight "${wl_name}" "${systemd_stage}" || return 1

  prev_owned="$(mktemp "${TMPDIR:-/tmp}/platform-prev-owned.XXXXXX")"
  prev_natives="$(mktemp "${TMPDIR:-/tmp}/platform-prev-natives.XXXXXX")"

  unit_bag_basenames "${WORKLOADS_ROOT}/${wl_name}/systemd" >"${prev_owned}" || true
  _workload_units_native_basenames "${WORKLOADS_ROOT}/${wl_name}/systemd" >"${prev_natives}" || true

  if ! workload_unit_sync_sot "${wl_name}" "${systemd_stage}"; then
    rc=1
  elif ! workload_unit_reconcile "${wl_name}" "${prev_owned}" "${prev_natives}"; then
    rc=1
  else
    if declare -F workload_units_before_reload >/dev/null 2>&1; then
      if ! workload_units_before_reload; then
        rc=1
      fi
    fi
    if [[ "${rc}" -eq 0 ]]; then
      quadlet_user_session_reload
      if ! workload_unit_apply_intent "${wl_name}" "${intent}"; then
        rc=1
      fi
    fi
  fi

  rm -f "${prev_owned}" "${prev_natives}"
  return "${rc}"
}

# Tear down Host unit install for one Workload's SoT basenames.
# Args: wl_name
# Removes farm directory symlink, flat platform drop-in dirs, and copied natives.
# Does NOT remove Host Volume Workload tree (SoT/Persist) via the symlink.
workload_units_purge() {
  local wl_name="${1:?workload name required}"
  local base ext farm_path
  local wl_dir="${WORKLOADS_ROOT}/${wl_name}"
  local bag="${wl_dir}/systemd"

  farm_path="$(unit_quadlet_farm_path workload "${wl_name}")" || return 1

  while IFS= read -r base; do
    [[ -n "${base}" ]] || continue
    workload_unit_stop_basename "${base}"
    ext="${base##*.}"
    # Platform drop-ins stay flat under UNIT_DIR even when units live in the farm.
    rm -rf "${UNIT_DIR}/${base}.d"
    if unit_ext_is_native "${ext}"; then
      rm -f "${SYSTEMD_USER_DIR}/${base}"
      rm -rf "${SYSTEMD_USER_DIR}/${base}.d"
    fi
  done < <(unit_bag_basenames "${bag}")

  if [[ -L "${farm_path}" ]]; then
    rm -f "${farm_path}"
  elif [[ -e "${farm_path}" ]]; then
    echo "workload_units_purge: farm path '${farm_path}' exists and is not a symlink" >&2
    return 1
  fi
}
