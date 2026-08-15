#!/usr/bin/env bash
# Workload unified systemd/ unit SoT helpers (sourced by Workload Setup / Purge).
# Expects after quadlet_user_session_begin: UNIT_DIR, SYSTEMD_USER_DIR, WORKLOADS_ROOT, USER_NAME.
# Optional: quadlet_user for start/stop after session reload.
#
# One bag: systemd/ holds Quadlet sources + native units (ADR-0054).
# Install: UNIT_DIR/workload-<basename> → directory symlink to Host Volume systemd/;
# natives copy into SYSTEMD_USER_DIR. Basename ownership spans farm + native dirs.

# shellcheck source=unit-consumers-host.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/unit-consumers-host.sh"

# Read unit file Key=value (comments and surrounding whitespace ignored).
# On match, prints the value to stdout.
workload_unit_file_key_value() {
  local file="$1"
  local key="$2"
  local line k v
  [[ -f "${file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "${line}" ]] || continue
    [[ "${line}" == *=* ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    k="${k%"${k##*[![:space:]]}"}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    if [[ "${k}" == "${key}" ]]; then
      printf '%s\n' "${v}"
      return 0
    fi
  done <"${file}"
  return 1
}

# True when unit file has Key=value (comments and surrounding whitespace ignored).
workload_unit_file_key_equals() {
  local file="$1"
  local key="$2"
  local want="$3"
  local got
  got="$(workload_unit_file_key_value "${file}" "${key}")" || return 1
  [[ "${got}" == "${want}" ]]
}

# Map a Quadlet unit filename to its generated user systemd unit (empty if none).
workload_quadlet_service_name() {
  local base="$1"
  local stem="${base%.*}"
  local ext="${base##*.}"
  case "${ext}" in
  container | kube) printf '%s\n' "${stem}.service" ;;
  pod) printf '%s\n' "${stem}-pod.service" ;;
  volume) printf '%s\n' "${stem}-volume.service" ;;
  network) printf '%s\n' "${stem}-network.service" ;;
  image) printf '%s\n' "${stem}-image.service" ;;
  build) printf '%s\n' "${stem}-build.service" ;;
  artifact) printf '%s\n' "${stem}-artifact.service" ;;
  *) printf '\n' ;;
  esac
}

# Map a native systemd unit filename to itself when Intent-managed (empty otherwise).
workload_systemd_unit_name() {
  local base="$1"
  local ext="${base##*.}"
  case "${ext}" in
  service | timer) printf '%s\n' "${base}" ;;
  *) printf '\n' ;;
  esac
}

# Classify authored unit by file kind: always-on | on-demand | ensure (empty = install-only).
# Args: base sot_file
workload_unit_kind() {
  local base="$1"
  local file="$2"
  local ext="${base##*.}"

  if unit_ext_is_quadlet "${ext}"; then
    case "${ext}" in
    volume | network | image | build | artifact)
      printf '%s\n' ensure
      ;;
    container)
      if workload_unit_file_key_equals "${file}" StartWithPod false; then
        printf '%s\n' on-demand
      else
        printf '%s\n' always-on
      fi
      ;;
    pod | kube)
      printf '%s\n' always-on
      ;;
    *)
      printf '\n'
      ;;
    esac
    return 0
  fi

  if unit_ext_is_native "${ext}"; then
    case "${ext}" in
    timer)
      printf '%s\n' on-demand
      ;;
    service)
      if workload_unit_file_key_equals "${file}" Type oneshot; then
        printf '%s\n' on-demand
      else
        printf '%s\n' always-on
      fi
      ;;
    *)
      printf '\n'
      ;;
    esac
    return 0
  fi

  printf '\n'
}

# True when a Quadlet container file sets non-empty Pod= (pod membership authorship).
workload_quadlet_container_has_pod_ref() {
  local file="$1"
  local pod_ref
  pod_ref="$(workload_unit_file_key_value "${file}" "Pod")" || return 1
  [[ -n "${pod_ref}" ]]
}

# Fail closed when any systemd/*.container Pod= names a missing or invalid target.
# Args: wl_name
workload_quadlet_validate_pod_refs() {
  local wl_name="$1"
  local sot_dir="${WORKLOADS_ROOT}/${wl_name}/systemd"
  local base file pod_ref ext
  [[ -d "${sot_dir}" ]] || return 0
  while IFS= read -r base; do
    [[ -n "${base}" ]] || continue
    [[ "${base##*.}" == container ]] || continue
    file="${sot_dir}/${base}"
    if ! workload_unit_file_key_value "${file}" "Pod" >/dev/null; then
      continue
    fi
    pod_ref="$(workload_unit_file_key_value "${file}" "Pod")"
    if [[ -z "${pod_ref}" ]]; then
      echo "workload unit ${base}: Pod must name a .pod or .kube unit in systemd/" >&2
      return 1
    fi
    ext="${pod_ref##*.}"
    case "${ext}" in
    pod | kube) ;;
    *)
      echo "workload unit ${base}: Pod=${pod_ref} must reference a .pod or .kube unit" >&2
      return 1
      ;;
    esac
    if [[ ! -f "${sot_dir}/${pod_ref}" ]]; then
      echo "workload unit ${base}: Pod=${pod_ref} missing from systemd/" >&2
      return 1
    fi
  done < <(unit_bag_basenames "${sot_dir}")
}

# List regular non-hidden basenames in a SoT directory (may be missing).
# Kept name for call-site stability during the bag cut.
workload_quadlet_sot_basenames() {
  unit_bag_basenames "${1:-}"
}

# True when basename exists in the Quadlet farm or native user systemd dir.
workload_unit_basename_exists_on_host() {
  unit_basename_exists_on_host "$1"
}

# Refuse basename if present on Host and not previously owned.
# Args: wl_name base prev_owned_file (union of previous SoT basenames)
workload_unit_refuse_foreign_basename() {
  local wl_name="$1"
  local base="$2"
  local prev_file="$3"
  local owned_before=0
  local p

  while IFS= read -r p; do
    [[ -n "${p}" ]] || continue
    if [[ "${p}" == "${base}" ]]; then
      owned_before=1
      break
    fi
  done <"${prev_file}"

  if workload_unit_basename_exists_on_host "${base}" && [[ "${owned_before}" -eq 0 ]]; then
    echo "workload unit basename '${base}' already exists in a Host unit directory (not owned by Workload '${wl_name}')" >&2
    return 1
  fi
}

# Sync staged systemd/ bag into Host Volume SoT for one Workload (replace tree).
# Args: wl_name stage_dir
workload_unit_sync_sot() {
  local wl_name="$1"
  local stage_dir="${2:-}"
  local dest="${WORKLOADS_ROOT}/${wl_name}/systemd"
  local src

  rm -rf "${dest}"
  if [[ -n "${stage_dir}" && -d "${stage_dir}" ]]; then
    mkdir -p "${dest}"
    for src in "${stage_dir}"/*; do
      [[ -f "${src}" ]] || continue
      [[ "$(basename "${src}")" == .* ]] && continue
      install -m 0644 "${src}" "${dest}/$(basename "${src}")"
    done
  fi
  if [[ -n "${USER_NAME:-}" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "${WORKLOADS_ROOT}/${wl_name}" 2>/dev/null || true
  fi
}

# Stop a managed unit for one basename (best-effort).
workload_unit_stop_basename() {
  local base="$1"
  local ext="${base##*.}"
  local svc=""
  if unit_ext_is_quadlet "${ext}"; then
    svc="$(workload_quadlet_service_name "${base}")"
  elif unit_ext_is_native "${ext}"; then
    svc="$(workload_systemd_unit_name "${base}")"
  fi
  if [[ -n "${svc}" ]] && declare -F quadlet_user >/dev/null 2>&1; then
    quadlet_user systemctl --user stop "${svc}" 2>/dev/null || true
  fi
}

# Install Quadlet farm directory symlink for a Workload (never per-file / never file symlink).
# Args: wl_name
workload_unit_install_quadlet_farm() {
  local wl_name="$1"
  local bag="${WORKLOADS_ROOT}/${wl_name}/systemd"
  local farm_id farm_path

  farm_id="$(unit_quadlet_farm_id workload "${wl_name}")" || return 1
  farm_path="${UNIT_DIR}/${farm_id}"
  mkdir -p "${UNIT_DIR}"

  if [[ -L "${farm_path}" ]]; then
    rm -f "${farm_path}"
  elif [[ -e "${farm_path}" ]]; then
    echo "workload unit farm path '${farm_path}' exists and is not a symlink" >&2
    return 1
  fi

  [[ -d "${bag}" ]] || {
    echo "workload unit farm: systemd bag missing for '${wl_name}'" >&2
    return 1
  }

  ln -s "${bag}" "${farm_path}" || return 1
  if [[ -n "${USER_NAME:-}" ]]; then
    chown -h "${USER_NAME}:${USER_NAME}" "${farm_path}" 2>/dev/null || true
  fi
}

# Copy native units from Workload SoT bag into SYSTEMD_USER_DIR; drop removed natives.
# Args: wl_name prev_natives_file
workload_unit_reconcile_natives() {
  local wl_name="$1"
  local prev_natives="$2"
  local sot_dir="${WORKLOADS_ROOT}/${wl_name}/systemd"
  local base ext still n
  local -a prev_bases=()
  local -a new_bases=()

  while IFS= read -r base; do
    [[ -n "${base}" ]] || continue
    prev_bases+=("${base}")
  done <"${prev_natives}"

  while IFS= read -r base; do
    [[ -n "${base}" ]] || continue
    ext="${base##*.}"
    unit_ext_is_native "${ext}" || continue
    new_bases+=("${base}")
  done < <(unit_bag_basenames "${sot_dir}")

  for base in "${prev_bases[@]+"${prev_bases[@]}"}"; do
    still=0
    for n in "${new_bases[@]+"${new_bases[@]}"}"; do
      if [[ "${n}" == "${base}" ]]; then
        still=1
        break
      fi
    done
    if [[ "${still}" -eq 0 ]]; then
      workload_unit_stop_basename "${base}"
      rm -f "${SYSTEMD_USER_DIR}/${base}"
    fi
  done

  for base in "${new_bases[@]+"${new_bases[@]}"}"; do
    install -m 0644 "${sot_dir}/${base}" "${SYSTEMD_USER_DIR}/${base}"
    if [[ -n "${USER_NAME:-}" ]]; then
      chown "${USER_NAME}:${USER_NAME}" "${SYSTEMD_USER_DIR}/${base}"
    fi
  done
}

# Reconcile Host install after SoT sync: farm symlink + native copies.
# Args: wl_name prev_owned_file prev_natives_file
workload_unit_reconcile() {
  local wl_name="$1"
  local prev_owned="$2"
  local prev_natives="$3"
  local base sot_dir="${WORKLOADS_ROOT}/${wl_name}/systemd"

  while IFS= read -r base; do
    [[ -n "${base}" ]] || continue
    workload_unit_refuse_foreign_basename "${wl_name}" "${base}" "${prev_owned}" || return 1
  done < <(unit_bag_basenames "${sot_dir}")

  workload_unit_install_quadlet_farm "${wl_name}" || return 1
  workload_unit_reconcile_natives "${wl_name}" "${prev_natives}" || return 1
}

# Apply Intent for one authored unit by kind (Workload-wide Intent; no partial Intent).
# Args: base sot_file intent
workload_unit_apply_basename_intent() {
  local base="$1"
  local file="$2"
  local intent="$3"
  local kind svc _
  local ext="${base##*.}"
  kind="$(workload_unit_kind "${base}" "${file}")"
  [[ -n "${kind}" ]] || return 0

  if unit_ext_is_quadlet "${ext}"; then
    svc="$(workload_quadlet_service_name "${base}")"
  elif unit_ext_is_native "${ext}"; then
    svc="$(workload_systemd_unit_name "${base}")"
  else
    return 0
  fi
  [[ -n "${svc}" ]] || return 0

  # Always-on pod members: pod graph owns restart/stop; Setup drives the pod only.
  if [[ "${kind}" == "always-on" && "${ext}" == "container" ]] &&
    workload_quadlet_container_has_pod_ref "${file}"; then
    return 0
  fi

  quadlet_user systemctl --user reset-failed "${svc}" 2>/dev/null || true

  if [[ "${intent}" == "run" ]]; then
    case "${kind}" in
    always-on)
      quadlet_user systemctl --user restart "${svc}"
      for _ in $(seq 1 30); do
        if quadlet_user systemctl --user --quiet is-active "${svc}"; then
          break
        fi
        sleep 1
      done
      quadlet_user systemctl --user --quiet is-active "${svc}"
      ;;
    on-demand)
      case "${ext}" in
      timer)
        quadlet_user systemctl --user enable --now "${svc}"
        ;;
      *)
        # Armed: installed so a condition can fire; job payloads not started by Setup.
        :
        ;;
      esac
      ;;
    ensure)
      # Create/pull/build once. restart (not start): re-ensure after resource
      # removal while the oneshot remains active (exited).
      quadlet_user systemctl --user restart "${svc}"
      ;;
    esac
  else
    # stop / trash
    case "${kind}" in
    always-on)
      quadlet_user systemctl --user stop "${svc}" 2>/dev/null || true
      ;;
    on-demand)
      case "${ext}" in
      timer)
        quadlet_user systemctl --user disable --now "${svc}" 2>/dev/null || true
        ;;
      *)
        # Disarm: stop any in-flight job instance.
        quadlet_user systemctl --user stop "${svc}" 2>/dev/null || true
        ;;
      esac
      ;;
    ensure)
      # Leave Ensure resources in place; unit files retained until Orphan Reap / Purge.
      :
      ;;
    esac
  fi
}

# Apply Intent across the Workload's current systemd/ SoT.
# Kind order: Ensure, then Always-on, then On-demand (Arm last).
workload_unit_apply_intent() {
  local wl_name="$1"
  local intent="$2"
  local base sot kind
  local -a ensure_args=()
  local -a always_args=()
  local -a ondemand_args=()
  local i

  workload_quadlet_validate_pod_refs "${wl_name}" || return 1

  sot="${WORKLOADS_ROOT}/${wl_name}/systemd"
  while IFS= read -r base; do
    [[ -n "${base}" ]] || continue
    kind="$(workload_unit_kind "${base}" "${sot}/${base}")"
    case "${kind}" in
    ensure) ensure_args+=("${base}" "${sot}/${base}") ;;
    always-on) always_args+=("${base}" "${sot}/${base}") ;;
    on-demand) ondemand_args+=("${base}" "${sot}/${base}") ;;
    esac
  done < <(unit_bag_basenames "${sot}")

  for ((i = 0; i < ${#ensure_args[@]}; i += 2)); do
    workload_unit_apply_basename_intent \
      "${ensure_args[i]}" "${ensure_args[i + 1]}" "${intent}"
  done
  for ((i = 0; i < ${#always_args[@]}; i += 2)); do
    workload_unit_apply_basename_intent \
      "${always_args[i]}" "${always_args[i + 1]}" "${intent}"
  done
  for ((i = 0; i < ${#ondemand_args[@]}; i += 2)); do
    workload_unit_apply_basename_intent \
      "${ondemand_args[i]}" "${ondemand_args[i + 1]}" "${intent}"
  done
}
