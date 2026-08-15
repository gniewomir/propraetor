#!/usr/bin/env bash
# Environment Configuration — Host half (ADR-0035 / ADR-0053 / #230).
# Sourced by ensure-workload-host, purge-orphans-host, and the operator module.
# Requires: HOME_DIR, UNIT_DIR, USER_NAME, WORKLOADS_ROOT (after quadlet_user_session_begin)
# for apply-or-clear. Fulfill-after-materialize needs only the tree.
#
# Public interface (three outcomes — Workload Setup / Orphan Reap share this seam):
#   environment_configuration_fulfill_after_materialize TREE
#     After Source resolve: full-fulfill Binding vs Artifact Requires on TREE.
#     Validate-only (no EnvironmentFile write). Non-empty Requires environment
#     also requires systemd/*.container. Reserved ROOT_* fail closed.
#   environment_configuration_apply_or_clear WL_NAME [RESOLVED_SRC]
#     Empty/unset RESOLVED_SRC → remove EnvironmentFile + Setup-owned env drop-ins.
#     Set → install EnvironmentFile + drop-ins for each SoT systemd/*.container.
#     Orphan Reap and omit-clear use empty RESOLVED_SRC.
#
# Binding remap vs select, bag/install details, containers gate, and reserved
# ROOT_* stay inside the module (not caller-facing).
#
# Operator outcome environment_configuration_stage_for_setup lives in
# internals/lib/environment/environment-configuration.sh (sources this file).

_ENV_HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Lazy-load Binding only for remap / fulfill (Orphan Reap apply-or-clear ships
# this file without binding.sh).
_environment_configuration_source_binding() {
  if declare -F artifact_binding_environment_remap >/dev/null 2>&1; then
    return 0
  fi
  local lib="${_ENV_HOST_DIR}/binding.sh"
  if [[ ! -f "${lib}" ]]; then
    lib="${_ENV_HOST_DIR}/../../lib/artifact/binding.sh"
  fi
  if [[ ! -f "${lib}" ]]; then
    echo "workload-environment-host: Artifact Binding library missing" >&2
    return 1
  fi
  # shellcheck source=../../lib/artifact/binding.sh
  source "${lib}"
}

workload_environment_path() {
  local wl_name="${1:?workload name required}"
  printf '%s/.config/platform/workloads/%s/environment\n' "${HOME_DIR}" "${wl_name}"
}

workload_environment_dropin_path() {
  local container_base="${1:?container basename required}"
  # container_base includes .container suffix, e.g. app.container
  printf '%s/%s.d/50-platform-environment.conf\n' "${UNIT_DIR}" "${container_base}"
}

workload_environment_remove_dropins_for_dir() {
  local systemd_dir="${1:-}"
  local base dropin_path dropin_dir
  [[ -d "${systemd_dir}" ]] || return 0
  for base in "${systemd_dir}"/*.container; do
    [[ -f "${base}" ]] || continue
    base="$(basename "${base}")"
    dropin_path="$(workload_environment_dropin_path "${base}")"
    dropin_dir="$(dirname "${dropin_path}")"
    rm -f "${dropin_path}"
    if [[ -d "${dropin_dir}" ]] && [[ -z "$(ls -A "${dropin_dir}" 2>/dev/null || true)" ]]; then
      rmdir "${dropin_dir}" 2>/dev/null || true
    fi
  done
}

# Internal: Binding remaps bag keys onto Requires environment names.
# When REQUIRES is set: full-fulfill Binding.environment onto Requires.environment.
# When omitted: Binding.environment only (zip Setup; Host full-fulfills later).
# Print bag_key=Requires_name one per line (Requires-name order). Empty
# environment → no lines. ROOT_DB_* / ROOT_CACHE_* bag keys or RHS names fail
# closed (ADR-0049 / ADR-0055).
environment_configuration_remap() {
  local binding="${1:?environment_configuration_remap: Binding path required}"
  local requires="${2-}"
  local pairs

  _environment_configuration_source_binding || return 1
  [[ -f "${binding}" ]] || {
    echo "Binding missing: ${binding}" >&2
    return 1
  }
  if [[ -n "${requires}" ]]; then
    [[ -f "${requires}" ]] || {
      echo "Requires missing: ${requires}" >&2
      return 1
    }
    pairs="$(artifact_binding_environment_remap "${binding}" "${requires}")" || return 1
  else
    pairs="$(artifact_binding_environment_select "${binding}")" || return 1
  fi
  python3 - "${pairs}" <<'PY' || return 1
import sys

reserved = (
    "ROOT_DB_USER",
    "ROOT_DB_PASSWORD",
    "ROOT_CACHE_USER",
    "ROOT_CACHE_PASSWORD",
)
for line in sys.argv[1].splitlines():
    if not line or "=" not in line:
        continue
    bag_key, _, req_name = line.partition("=")
    if bag_key in reserved or req_name in reserved:
        name = bag_key if bag_key in reserved else req_name
        if name.startswith("ROOT_CACHE_"):
            raise SystemExit(
                f"Binding must not remap Cache admin credential {name} into a "
                "Workload (ADR-0055)"
            )
        raise SystemExit(
            f"Binding must not remap Database admin credential {name} into a "
            "Workload (ADR-0049)"
        )
PY
  if [[ -n "${pairs}" ]]; then
    printf '%s\n' "${pairs}"
  fi
}

# Internal: fail closed when ACTIVE=1 but TREE has no systemd/*.container.
environment_configuration_require_containers() {
  local tree="${1:?workload tree required}"
  local active="${2:?WL_ENV_ACTIVE required}"
  [[ "${active}" == "1" ]] || return 0
  local found=0
  local f
  if [[ -d "${tree}/systemd" ]]; then
    for f in "${tree}/systemd"/*.container; do
      [[ -f "${f}" ]] || continue
      found=1
      break
    done
  fi
  if [[ "${found}" -ne 1 ]]; then
    echo "Environment Configuration requires systemd/*.container when Requires environment is non-empty" >&2
    return 1
  fi
  return 0
}

# Internal: install or remove EnvironmentFile + drop-ins.
environment_configuration_install_host() {
  local wl_name="${1:?workload name required}"
  local resolved_src="${2:-}"
  local env_path dropin_path base dest_dir sot_systemd

  env_path="$(workload_environment_path "${wl_name}")"
  dest_dir="$(dirname "${env_path}")"
  sot_systemd="${WORKLOADS_ROOT}/${wl_name}/systemd"

  if [[ -z "${resolved_src}" ]]; then
    workload_environment_remove_dropins_for_dir "${sot_systemd}"
    # Remove only the EnvironmentFile — sibling Database bindings live under
    # the same Platform User Workload tree (ADR-0049 / #189).
    rm -f "${env_path}"
    if [[ -d "${dest_dir}" ]] && [[ -z "$(ls -A "${dest_dir}" 2>/dev/null || true)" ]]; then
      rmdir "${dest_dir}" 2>/dev/null || true
    fi
    return 0
  fi

  [[ -f "${resolved_src}" ]] || {
    echo "Environment Configuration resolved file missing: ${resolved_src}" >&2
    return 1
  }

  mkdir -p "${dest_dir}"
  install -m 0600 "${resolved_src}" "${env_path}"
  chown -R "${USER_NAME}:${USER_NAME}" "${dest_dir}" 2>/dev/null || true

  for base in "${sot_systemd}"/*.container; do
    [[ -f "${base}" ]] || continue
    base="$(basename "${base}")"
    dropin_path="$(workload_environment_dropin_path "${base}")"
    mkdir -p "$(dirname "${dropin_path}")"
    cat >"${dropin_path}" <<EOF
[Container]
EnvironmentFile=${env_path}
EOF
    chown -R "${USER_NAME}:${USER_NAME}" "$(dirname "${dropin_path}")" 2>/dev/null || true
  done
  return 0
}

# Outcome: after materialize, full-fulfill Binding × Artifact Requires (validate-only).
environment_configuration_fulfill_after_materialize() {
  local tree="${1:?environment_configuration_fulfill_after_materialize: materialized tree required}"
  local pairs

  [[ -f "${tree}/binding.json" ]] || {
    echo "Binding missing: ${tree}/binding.json" >&2
    return 1
  }
  [[ -f "${tree}/requires.json" ]] || {
    echo "Requires missing: ${tree}/requires.json" >&2
    return 1
  }
  pairs="$(environment_configuration_remap "${tree}/binding.json" "${tree}/requires.json")" \
    || return 1
  if [[ -n "${pairs}" ]]; then
    environment_configuration_require_containers "${tree}" 1 || return 1
  fi
  return 0
}

# Outcome: install from RESOLVED_SRC, or clear when empty/unset (Setup omit + Orphan Reap).
environment_configuration_apply_or_clear() {
  local wl_name="${1:?workload name required}"
  local resolved_src="${2:-}"
  environment_configuration_install_host "${wl_name}" "${resolved_src}"
}
