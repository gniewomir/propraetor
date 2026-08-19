#!/usr/bin/env bash
# Deep Identity Component Setup (ADR-0057 / #252 / #253).
# Sourced by Identity pre-workloads.sh / post-workloads.sh.
# Standing ensure: admin EnvironmentFile, Pocket ID on Service Network dial name `identity`.
# Declaration gather: API permission catalogs → Environment-scoped Pocket ID resource server.
#
# Ambient (optional overrides for offline tests):
#   USER_NAME, DATA_ROOT, WORKLOADS_ROOT, ENV_SLUG
# After begin: HOME_DIR / UNIT_DIR / SYSTEMD_USER_DIR via quadlet_user_session_begin.
#
# Args: component_tree [staged_admin_env_src]

_identity_setup_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=host-volume-paths-host.sh
source "${_identity_setup_lib_dir}/host-volume-paths-host.sh"
# shellcheck source=quadlet-user-session.sh
source "${_identity_setup_lib_dir}/quadlet-user-session.sh"
# shellcheck source=component-units-host.sh
source "${_identity_setup_lib_dir}/component-units-host.sh"
# shellcheck source=component-handoff-host.sh
source "${_identity_setup_lib_dir}/component-handoff-host.sh"
# shellcheck source=identity-admin-env-host.sh
source "${_identity_setup_lib_dir}/identity-admin-env-host.sh"
# shellcheck source=identity-fulfill-host.sh
source "${_identity_setup_lib_dir}/identity-fulfill-host.sh"

# Wait until Pocket ID answers OIDC discovery inside the identity-pocket-id container.
identity_wait_ready() {
  local _
  local cname="identity-pocket-id"
  local state=""

  for _ in $(seq 1 360); do
    state="$(quadlet_user systemctl --user show -p ActiveState --value identity-pocket-id.service 2>/dev/null || true)"
    if [[ "${state}" == "failed" ]]; then
      echo "Identity: identity-pocket-id.service failed before ready" >&2
      return 1
    fi
    if quadlet_user env "HOME=${HOME_DIR}" bash -c \
      "cd \"\$HOME\" && podman exec ${cname} wget -q -O - http://127.0.0.1:1411/.well-known/openid-configuration" \
      2>/dev/null | grep -Fq '"issuer"'; then
      return 0
    fi
    sleep 1
  done
  echo "Identity: Pocket ID did not become ready (OIDC discovery)" >&2
  return 1
}

# Standing ensure: units / admin env / data dir — not Declaration converge.
# Args: component_tree [staged_admin_env_src]
identity_standing_ensure() {
  local component_tree="${1:?identity_standing_ensure: component tree required}"
  shift
  local staged_admin_env=""

  if [[ $# -gt 0 && "$1" != --* ]]; then
    staged_admin_env="$1"
    shift
  fi
  if [[ $# -gt 0 ]]; then
    echo "identity_standing_ensure: unknown argument: $1" >&2
    return 1
  fi

  [[ -n "${staged_admin_env}" ]] || staged_admin_env="$(component_handoff_identity_admin_env)"

  USER_NAME="${USER_NAME:-platform}"
  DATA_ROOT="${DATA_ROOT:-$(host_volume_component_persist identity)}"
  WORKLOADS_ROOT="${WORKLOADS_ROOT:-$(host_volume_workloads_sot_root)}"
  ADMIN_ENV="${DATA_ROOT}/admin/environment"
  ENV_SLUG="${ENV_SLUG:-$(component_handoff_environment_slug)}"

  quadlet_user_session_begin

  mkdir -p "${DATA_ROOT}" "${DATA_ROOT}/admin" "${DATA_ROOT}/data"

  identity_install_admin_env "${staged_admin_env}" || return 1

  component_units_install "${component_tree}" component "$(basename "${component_tree}")" || return 1

  chown -R "${USER_NAME}:${USER_NAME}" "${HOME_DIR}/.config" 2>/dev/null || true
  for leaf in admin data; do
    if [[ -e "${DATA_ROOT}/${leaf}" ]]; then
      chown -R "${USER_NAME}:${USER_NAME}" "${DATA_ROOT}/${leaf}" 2>/dev/null || true
    fi
  done
  chown "${USER_NAME}:${USER_NAME}" "${DATA_ROOT}" 2>/dev/null || true

  quadlet_user_session_reload
  quadlet_user systemctl --user reset-failed \
    identity-pod.service identity-pocket-id.service 2>/dev/null || true

  quadlet_user systemctl --user restart identity-pod.service
  quadlet_user systemctl --user --quiet is-active identity-pod.service || {
    echo "Identity: identity-pod.service is not active" >&2
    quadlet_user systemctl --user status identity-pod.service identity-pocket-id.service --no-pager >&2 || true
    return 1
  }

  identity_wait_ready || {
    quadlet_user systemctl --user status identity-pod.service identity-pocket-id.service --no-pager >&2 || true
    return 1
  }
}

identity_setup_pre_workloads() {
  local component_tree="${1:?identity_setup_pre_workloads: component tree required}"
  local staged_admin_env="${2:-}"
  identity_standing_ensure "${component_tree}" "${staged_admin_env}" || return 1
  identity_fulfill_declarations || return 1
}

identity_setup_post_workloads() {
  local component_tree="${1:?identity_setup_post_workloads: component tree required}"
  local staged_admin_env="${2:-}"
  identity_standing_ensure "${component_tree}" "${staged_admin_env}" || return 1
  identity_drop_absent_fulfillments || return 1
}
