#!/usr/bin/env bash
# Shared Declaration claim lifecycle (gather → prepare → publish/unpublish → orphan).
# Component adapters (Cache ACL now; Database role/db in #231) supply hooks.
# ADR-0055: share this shell only — keep Components and Persist CAs distinct.
#
# Ambient (set by Component Setup begin): HOME_DIR, UNIT_DIR, USER_NAME,
# WORKLOADS_ROOT, DATA_ROOT / CLIENTS_DIR as needed by adapters.
#
# Public interface:
#   declaration_binding_dir WL_NAME BINDING_KIND
#   declaration_dropin_path CONTAINER_BASE DROPIN_LEAF
#   declaration_publish_mtls_binding WL_NAME BINDING_KIND DROPIN_LEAF MOUNT_ROOT WRITE_ENV_FN
#   declaration_unpublish_mtls_binding WL_NAME BINDING_KIND DROPIN_LEAF
#   declaration_absent_client_basenames [CLIENTS_DIR [WORKLOADS_ROOT]]
#   declaration_workload_is_run_claimant WL_DIR REQUIRES_READER_FN
#   declaration_converge_claims WORKLOADS_ROOT LABEL RESERVED_BASENAME \
#       IS_CLAIMANT_FN VALIDATE_BASENAME_FN PREPARE_FN FULFILL_ONE_FN \
#       UNPUBLISH_ONE_FN BINDING_DIR_FN
#   declaration_drop_absent_fulfillments WORKLOADS_ROOT CLIENTS_DIR DROP_ONE_FN
#
# Hook callables are function names invoked as: fn ARG… (Bash 3.2-safe).
# VALIDATE_BASENAME_FN may be empty to skip. PREPARE_FN receives the sorted
# claimants file path. FULFILL/UNPUBLISH/DROP/BINDING_DIR receive the basename.

_declaration_converge_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workload-manifest-host.sh
source "${_declaration_converge_lib_dir}/workload-manifest-host.sh"

# Platform User path for one Workload's published binding directory.
# BINDING_KIND is the Component leaf (e.g. cache, database).
declaration_binding_dir() {
  local wl_name="${1:?declaration_binding_dir: workload name required}"
  local binding_kind="${2:?declaration_binding_dir: binding kind required}"
  printf '%s/.config/platform/workloads/%s/%s\n' "${HOME_DIR}" "${wl_name}" "${binding_kind}"
}

declaration_dropin_path() {
  local container_base="${1:?declaration_dropin_path: container basename required}"
  local dropin_leaf="${2:?declaration_dropin_path: drop-in leaf required}"
  printf '%s/%s.d/%s\n' "${UNIT_DIR}" "${container_base}" "${dropin_leaf}"
}

# Publish mTLS binding + Setup-owned Quadlet drop-in for one Workload.
# WRITE_ENV_FN ENV_PATH WL_NAME MOUNT_ROOT writes the EnvironmentFile body + mode.
declaration_publish_mtls_binding() {
  local wl_name="${1:?declaration_publish_mtls_binding: workload name required}"
  local binding_kind="${2:?declaration_publish_mtls_binding: binding kind required}"
  local dropin_leaf="${3:?declaration_publish_mtls_binding: drop-in leaf required}"
  local mount_root="${4:?declaration_publish_mtls_binding: mount root required}"
  local write_env_fn="${5:?declaration_publish_mtls_binding: write-env fn required}"
  local binding_dir client_dir ca_crt client_crt client_key env_path
  local sot_systemd base dropin_path

  client_dir="${DATA_ROOT}/clients/${wl_name}"
  ca_crt="${DATA_ROOT}/ca/ca.crt"
  client_crt="${client_dir}/client.crt"
  client_key="${client_dir}/client.key"
  [[ -f "${ca_crt}" && -f "${client_crt}" && -f "${client_key}" ]] || {
    echo "Declaration publish (${binding_kind}): client material missing for '${wl_name}'" >&2
    return 1
  }

  binding_dir="$(declaration_binding_dir "${wl_name}" "${binding_kind}")"
  mkdir -p "${binding_dir}"
  install -m 0644 "${ca_crt}" "${binding_dir}/ca.crt"
  install -m 0644 "${client_crt}" "${binding_dir}/client.crt"
  install -m 0600 "${client_key}" "${binding_dir}/client.key"

  env_path="${binding_dir}/environment"
  "${write_env_fn}" "${env_path}" "${wl_name}" "${mount_root}" || return 1

  sot_systemd="${WORKLOADS_ROOT}/${wl_name}/systemd"
  if [[ -d "${sot_systemd}" ]]; then
    for base in "${sot_systemd}"/*.container; do
      [[ -f "${base}" ]] || continue
      base="$(basename "${base}")"
      dropin_path="$(declaration_dropin_path "${base}" "${dropin_leaf}")"
      mkdir -p "$(dirname "${dropin_path}")"
      cat >"${dropin_path}" <<EOF
[Container]
EnvironmentFile=${env_path}
Volume=${binding_dir}/ca.crt:${mount_root}/ca.crt:ro
Volume=${binding_dir}/client.crt:${mount_root}/client.crt:ro
Volume=${binding_dir}/client.key:${mount_root}/client.key:ro
EOF
      if [[ -n "${USER_NAME:-}" ]]; then
        chown -R "${USER_NAME}:${USER_NAME}" "$(dirname "${dropin_path}")" 2>/dev/null || true
      fi
    done
  fi

  if [[ -n "${USER_NAME:-}" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "$(dirname "${binding_dir}")" 2>/dev/null || true
  fi
}

# Clear published binding + Setup-owned drop-ins for one Workload.
# When SoT is already gone, clears the binding dir and conventional drop-in leftover.
declaration_unpublish_mtls_binding() {
  local wl_name="${1:?declaration_unpublish_mtls_binding: workload name required}"
  local binding_kind="${2:?declaration_unpublish_mtls_binding: binding kind required}"
  local dropin_leaf="${3:?declaration_unpublish_mtls_binding: drop-in leaf required}"
  local binding_dir sot_systemd base dropin_path dropin_dir wl_cfg_dir

  binding_dir="$(declaration_binding_dir "${wl_name}" "${binding_kind}")"
  rm -rf "${binding_dir}"
  wl_cfg_dir="$(dirname "${binding_dir}")"
  if [[ -d "${wl_cfg_dir}" ]] && [[ -z "$(ls -A "${wl_cfg_dir}" 2>/dev/null || true)" ]]; then
    rmdir "${wl_cfg_dir}" 2>/dev/null || true
  fi

  sot_systemd="${WORKLOADS_ROOT}/${wl_name}/systemd"
  if [[ -d "${sot_systemd}" ]]; then
    for base in "${sot_systemd}"/*.container; do
      [[ -f "${base}" ]] || continue
      base="$(basename "${base}")"
      dropin_path="$(declaration_dropin_path "${base}" "${dropin_leaf}")"
      rm -f "${dropin_path}"
      dropin_dir="$(dirname "${dropin_path}")"
      if [[ -d "${dropin_dir}" ]] && [[ -z "$(ls -A "${dropin_dir}" 2>/dev/null || true)" ]]; then
        rmdir "${dropin_dir}" 2>/dev/null || true
      fi
    done
  else
    dropin_path="$(declaration_dropin_path "${wl_name}.container" "${dropin_leaf}")"
    rm -f "${dropin_path}"
    dropin_dir="$(dirname "${dropin_path}")"
    if [[ -d "${dropin_dir}" ]] && [[ -z "$(ls -A "${dropin_dir}" 2>/dev/null || true)" ]]; then
      rmdir "${dropin_dir}" 2>/dev/null || true
    fi
  fi
}

# Print client basenames under CLIENTS_DIR whose Workload SoT Manifest is gone.
# Pure selection helper (offline-testable); one basename per line, sorted.
declaration_absent_client_basenames() {
  local clients_dir="${1:-${CLIENTS_DIR-}}"
  local workloads_root="${2:-${WORKLOADS_ROOT-}}"
  local d name

  if [[ -z "${clients_dir}" ]]; then
    echo "declaration_absent_client_basenames: clients dir required" >&2
    return 1
  fi
  if [[ -z "${workloads_root}" ]]; then
    echo "declaration_absent_client_basenames: workloads root required" >&2
    return 1
  fi
  [[ -d "${clients_dir}" ]] || return 0

  for d in "${clients_dir}"/*; do
    [[ -d "${d}" ]] || continue
    name="$(basename "${d}")"
    if [[ ! -f "${workloads_root}/${name}/manifest.json" ]]; then
      printf '%s\n' "${name}"
    fi
  done | LC_ALL=C sort -u
}

# Print 1 when Intent-run and REQUIRES_READER_FN returns 1, else 0.
# Fail closed on invalid Manifest Intent or Requires reader failure.
declaration_workload_is_run_claimant() {
  local wl_dir="${1:?declaration_workload_is_run_claimant: workload tree required}"
  local requires_reader_fn="${2:?declaration_workload_is_run_claimant: requires reader fn required}"
  local intent claims

  intent="$(workload_manifest_intent "${wl_dir}/manifest.json")" || return 1
  [[ "${intent}" == "run" ]] || {
    printf '0\n'
    return 0
  }
  claims="$("${requires_reader_fn}" "${wl_dir}/requires.json")" || return 1
  printf '%s\n' "${claims}"
}

_declaration_is_claimant() {
  local wl_name="$1"
  local claimants_file="$2"
  grep -Fxq "${wl_name}" "${claimants_file}" 2>/dev/null
}

# Gather Intent-run claimants; prepare; fulfill each; unpublish non-claimants.
# VALIDATE_BASENAME_FN may be "" to skip basename safety checks.
declaration_converge_claims() {
  local workloads_root="${1:?declaration_converge_claims: workloads root required}"
  local label="${2:?declaration_converge_claims: label required}"
  local reserved_basename="${3:?declaration_converge_claims: reserved basename required}"
  local is_claimant_fn="${4:?declaration_converge_claims: is-claimant fn required}"
  local validate_basename_fn="${5-}"
  local prepare_fn="${6:?declaration_converge_claims: prepare fn required}"
  local fulfill_one_fn="${7:?declaration_converge_claims: fulfill-one fn required}"
  local unpublish_one_fn="${8:?declaration_converge_claims: unpublish-one fn required}"
  local binding_dir_fn="${9:?declaration_converge_claims: binding-dir fn required}"
  local wl_dir wl_name claims
  local claimants_file sorted_file
  local had_binding
  local IFS

  if [[ -z "${workloads_root}" ]]; then
    echo "declaration_converge_claims: workloads root required" >&2
    return 1
  fi

  command -v python3 >/dev/null || {
    echo "declaration_converge_claims: python3 required" >&2
    return 1
  }

  claimants_file="$(mktemp "${TMPDIR:-/tmp}/platform-declaration-claimants.XXXXXX")"
  sorted_file="$(mktemp "${TMPDIR:-/tmp}/platform-declaration-claimants-sorted.XXXXXX")"
  : >"${claimants_file}"

  if [[ -d "${workloads_root}" ]]; then
    for wl_dir in "${workloads_root}"/*; do
      [[ -d "${wl_dir}" && -f "${wl_dir}/manifest.json" ]] || continue
      wl_name="$(basename "${wl_dir}")"
      if [[ "${wl_name}" == "${reserved_basename}" ]]; then
        rm -f "${claimants_file}" "${sorted_file}"
        echo "${label} gather: Workload basename '${reserved_basename}' is reserved" >&2
        return 1
      fi
      claims="$("${is_claimant_fn}" "${wl_dir}")" || {
        rm -f "${claimants_file}" "${sorted_file}"
        return 1
      }
      [[ "${claims}" == "1" ]] || continue
      if [[ -n "${validate_basename_fn}" ]]; then
        if ! "${validate_basename_fn}" "${wl_name}"; then
          rm -f "${claimants_file}" "${sorted_file}"
          return 1
        fi
      fi
      printf '%s\n' "${wl_name}" >>"${claimants_file}"
    done
  fi

  LC_ALL=C sort -u "${claimants_file}" >"${sorted_file}"
  rm -f "${claimants_file}"

  "${prepare_fn}" "${sorted_file}" || {
    rm -f "${sorted_file}"
    return 1
  }

  while IFS= read -r wl_name; do
    [[ -n "${wl_name}" ]] || continue
    "${fulfill_one_fn}" "${wl_name}" || {
      rm -f "${sorted_file}"
      return 1
    }
    echo "${label}: fulfilled binding for Workload '${wl_name}'" >&2
  done <"${sorted_file}"

  if [[ -d "${workloads_root}" ]]; then
    for wl_dir in "${workloads_root}"/*; do
      [[ -d "${wl_dir}" && -f "${wl_dir}/manifest.json" ]] || continue
      wl_name="$(basename "${wl_dir}")"
      if _declaration_is_claimant "${wl_name}" "${sorted_file}"; then
        continue
      fi
      had_binding=0
      if [[ -d "$("${binding_dir_fn}" "${wl_name}")" ]]; then
        had_binding=1
      fi
      "${unpublish_one_fn}" "${wl_name}" || {
        rm -f "${sorted_file}"
        return 1
      }
      if [[ "${had_binding}" -eq 1 ]]; then
        echo "${label}: unpublished binding for Workload '${wl_name}'" >&2
      fi
    done
  fi

  rm -f "${sorted_file}"
  return 0
}

# post-workloads: DROP_ONE_FN for each Orphan-absent client basename.
declaration_drop_absent_fulfillments() {
  local workloads_root="${1:?declaration_drop_absent_fulfillments: workloads root required}"
  local clients_dir="${2:?declaration_drop_absent_fulfillments: clients dir required}"
  local drop_one_fn="${3:?declaration_drop_absent_fulfillments: drop-one fn required}"
  local wl_name

  if [[ -z "${workloads_root}" ]]; then
    echo "declaration_drop_absent_fulfillments: workloads root required" >&2
    return 1
  fi

  while IFS= read -r wl_name; do
    [[ -n "${wl_name}" ]] || continue
    "${drop_one_fn}" "${wl_name}" || return 1
  done < <(declaration_absent_client_basenames "${clients_dir}" "${workloads_root}")
}
