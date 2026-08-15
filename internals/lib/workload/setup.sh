#!/usr/bin/env bash
# Workload Setup operator payload assembly (#233).
# Sourced by internals/ensure-workload.sh — not an operator entrypoint.
#
# Public interface:
#   workload_setup_stage_payload STAGE REMOTE_ROOT MANIFEST_DIR
#     Identity-check the Workload basename, stage shared projection ship
#     inventory + Setup-only Host libs + entry script, copy the Workload tree,
#     and stage Environment Configuration. Sets WL_ENV_RESOLVED_REMOTE (ambient
#     from envcfg). Callers then host_delivery_run — they do not own ship-lists.

_WL_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WL_SETUP_REPO="$(cd "${_WL_SETUP_DIR}/../../.." && pwd)"
_WL_SETUP_HOST_SCRIPTS="${_WL_SETUP_REPO}/internals/host-scripts"
_WL_SETUP_HOST_LIB="${_WL_SETUP_HOST_SCRIPTS}/lib"
_WL_SETUP_ARTIFACT="${_WL_SETUP_REPO}/internals/lib/artifact"

# shellcheck source=project-ship.sh
source "${_WL_SETUP_DIR}/project-ship.sh"
# shellcheck source=../environment/environment-configuration.sh
source "${_WL_SETUP_DIR}/../environment/environment-configuration.sh"
# shellcheck source=../../host-scripts/lib/workload-identity-host.sh
source "${_WL_SETUP_HOST_LIB}/workload-identity-host.sh"
# shellcheck source=../artifact/source.sh
source "${_WL_SETUP_ARTIFACT}/source.sh"

workload_setup_stage_payload() {
  local stage="${1:?workload_setup_stage_payload: STAGE required}"
  local remote_root="${2:?workload_setup_stage_payload: REMOTE_ROOT required}"
  local manifest_dir="${3:?workload_setup_stage_payload: MANIFEST_DIR required}"
  local wl_name manifest_abs binding_abs requires_abs env_dir wl_source

  [[ -d "${stage}" ]] || {
    echo "workload_setup_stage_payload: STAGE is not a directory: ${stage}" >&2
    return 1
  }
  [[ -d "${manifest_dir}" ]] || {
    echo "workload_setup_stage_payload: Workload tree missing: ${manifest_dir}/" >&2
    return 1
  }

  wl_name="$(basename "${manifest_dir}")"
  workload_identity_require "${wl_name}" || return 1

  manifest_abs="${manifest_dir}/manifest.json"
  binding_abs="${manifest_dir}/binding.json"
  [[ -f "${manifest_abs}" ]] || {
    echo "manifest.json missing in ${manifest_dir}/" >&2
    return 1
  }
  [[ -f "${binding_abs}" ]] || {
    echo "binding.json missing in ${manifest_dir}/" >&2
    return 1
  }

  wl_source="$(artifact_source_from_manifest "${manifest_abs}")" || return 1
  requires_abs="${manifest_dir}/requires.json"
  if [[ "${wl_source}" == "internal" ]]; then
    [[ -f "${requires_abs}" ]] || {
      echo "requires.json missing in ${manifest_dir}/" >&2
      return 1
    }
  else
    requires_abs=""
  fi

  env_dir="$(cd "${manifest_dir}/.." && pwd)" || return 1

  workload_project_stage_ship_inventory "${stage}" || return 1

  cp "${_WL_SETUP_HOST_SCRIPTS}/ensure-workload-host.sh" \
    "${stage}/ensure-workload-host.sh" || return 1
  cp "${_WL_SETUP_HOST_LIB}/workload-setup-host.sh" \
    "${stage}/workload-setup-host.sh" || return 1
  cp "${_WL_SETUP_HOST_LIB}/workload-identity-host.sh" \
    "${stage}/workload-identity-host.sh" || return 1
  cp "${_WL_SETUP_HOST_LIB}/workload-units-host.sh" \
    "${stage}/workload-units-host.sh" || return 1
  cp "${_WL_SETUP_HOST_LIB}/workload-quadlets-host.sh" \
    "${stage}/workload-quadlets-host.sh" || return 1
  cp "${_WL_SETUP_HOST_LIB}/workload-environment-host.sh" \
    "${stage}/workload-environment-host.sh" || return 1
  cp "${_WL_SETUP_HOST_LIB}/workload-manifest-host.sh" \
    "${stage}/workload-manifest-host.sh" || return 1
  cp "${_WL_SETUP_HOST_LIB}/quadlet-user-session.sh" \
    "${stage}/quadlet-user-session.sh" || return 1
  cp "${_WL_SETUP_ARTIFACT}/manifest.sh" "${stage}/manifest.sh" || return 1
  cp "${_WL_SETUP_ARTIFACT}/binding.sh" "${stage}/binding.sh" || return 1
  cp "${_WL_SETUP_ARTIFACT}/requires.sh" "${stage}/requires.sh" || return 1

  mkdir -p "${stage}/${wl_name}" || return 1
  cp -a "${manifest_dir}/." "${stage}/${wl_name}/" || return 1

  environment_configuration_stage_for_setup \
    "${stage}" "${binding_abs}" "${requires_abs}" "${env_dir}" "${manifest_dir}" \
    "${remote_root}" || return 1

  return 0
}
