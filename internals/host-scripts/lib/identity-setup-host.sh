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

# True when the identity-pocket-id container is running.
identity_pocket_id_container_running() {
  quadlet_user env "HOME=${HOME_DIR:?}" bash -c \
    'podman ps -q --filter name=identity-pocket-id' 2>/dev/null | grep -q .
}

# Pocket ID v2 holds a SQLite application_lock; a fast restart can fail while the
# prior instance still holds (or has not yet released) the lock. Stop gracefully,
# wait for the container to exit, then clear a stale lock when nothing is running.
identity_stop_pod_gracefully() {
  local _

  quadlet_user systemctl --user stop identity-pocket-id.service 2>/dev/null || true
  quadlet_user systemctl --user stop identity-pod.service 2>/dev/null || true
  for _ in $(seq 1 30); do
    if ! identity_pocket_id_container_running; then
      break
    fi
    sleep 1
  done
  sleep 2
}

# Remove a leftover application_lock row when Pocket ID is not running.
identity_clear_stale_app_lock_if_idle() {
  local db="${DATA_ROOT:?}/data/pocket-id.db"

  identity_pocket_id_container_running && return 0
  [[ -f "${db}" ]] || return 0
  command -v sqlite3 >/dev/null || return 0
  sqlite3 "${db}" "DELETE FROM kv WHERE key = 'application_lock';" 2>/dev/null || true
}

# Start the Identity pod (never restart — Pocket ID lock release needs a clean stop).
identity_start_pod() {
  quadlet_user systemctl --user reset-failed \
    identity-pod.service identity-pocket-id.service 2>/dev/null || true
  quadlet_user systemctl --user start identity-pod.service
}

# True when Pocket ID already answers OIDC discovery (skip unnecessary recycle).
identity_pod_already_ready() {
  quadlet_user systemctl --user is-active --quiet identity-pod.service 2>/dev/null \
    && quadlet_user systemctl --user is-active --quiet identity-pocket-id.service 2>/dev/null \
    && quadlet_user env "HOME=${HOME_DIR:?}" bash -c \
      "cd \"\$HOME\" && podman exec identity-pocket-id wget -q --timeout=5 --tries=1 -O - http://127.0.0.1:1411/.well-known/openid-configuration" \
      2>/dev/null | grep -Fq '"issuer"' \
    # OIDC discovery is reachable; later converge steps may still retry
    # Pocket ID admin API calls if needed.
}

# True when Pocket ID admin API responds with JSON.
identity_admin_api_ready() {
  # When Pocket ID is up but admin routes are not yet usable, later catalog
  # converge steps can fail with non-JSON bodies (causing downstream python
  # decode crashes in Acceptance).
  command -v python3 >/dev/null || return 1

  local api_json
  api_json="$(
    identity_pocket_id_admin_curl GET "/api/apis?pagination[page]=1&pagination[limit]=100" 2>/dev/null \
      || return 1
  )" || return 1

  printf '%s\n' "${api_json}" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null
}

# Wait until Pocket ID answers OIDC discovery inside the identity-pocket-id container.
identity_wait_ready() {
  local _
  local cname="identity-pocket-id"
  local state=""

  for _ in $(seq 1 180); do
    state="$(quadlet_user systemctl --user show -p ActiveState --value identity-pocket-id.service 2>/dev/null || true)"
    if [[ "${state}" == "failed" ]]; then
      echo "Identity: identity-pocket-id.service failed before ready" >&2
      return 1
    fi
    if quadlet_user env "HOME=${HOME_DIR}" bash -c \
      "cd \"\$HOME\" && podman exec ${cname} wget -q --timeout=5 --tries=1 -O - http://127.0.0.1:1411/.well-known/openid-configuration" \
      2>/dev/null | grep -Fq '"issuer"'; then
      return 0
    fi
    sleep 1
  done
  echo "Identity: Pocket ID did not become ready (OIDC discovery)" >&2
  return 1
}

# First-admin bootstrap (ADR-0057): when Pocket ID has zero real users, create
# the operator admin from IDENTITY_ADMIN_EMAIL and print a one-time login URL
# https://<fqdn>/lc/{token} on stderr. Noop when setup is already completed.
# Ambient: ADMIN_ENV (must contain IDENTITY_ADMIN_EMAIL + APP_URL).
identity_bootstrap_first_admin() {
  local status email app_url username user_json user_id token login_url
  status="$(identity_pocket_id_signup_setup_status)" || return 1
  case "${status}" in
    completed) return 0 ;;
    available) ;;
    *)
      echo "Identity: unexpected signup setup status: ${status}" >&2
      return 1
      ;;
  esac

  [[ -n "${ADMIN_ENV:-}" && -f "${ADMIN_ENV}" ]] || {
    echo "Identity: ADMIN_ENV required for first-admin bootstrap" >&2
    return 1
  }
  email="$(grep -E '^IDENTITY_ADMIN_EMAIL=' "${ADMIN_ENV}" | head -n1 | cut -d= -f2- || true)"
  app_url="$(grep -E '^APP_URL=' "${ADMIN_ENV}" | head -n1 | cut -d= -f2- || true)"
  [[ -n "${email}" ]] || {
    echo "Identity: IDENTITY_ADMIN_EMAIL missing for first-admin bootstrap" >&2
    return 1
  }
  [[ -n "${app_url}" ]] || {
    echo "Identity: APP_URL missing for first-admin bootstrap" >&2
    return 1
  }
  app_url="${app_url%/}"

  username="$(python3 - "${email}" <<'PY'
import re, sys
email = sys.argv[1]
local = email.split("@", 1)[0]
# Pocket ID username: ^[a-zA-Z0-9]([a-zA-Z0-9_.@-]*[a-zA-Z0-9])?$
cleaned = re.sub(r"[^a-zA-Z0-9_.@-]", "", local)
cleaned = re.sub(r"^[^a-zA-Z0-9]+", "", cleaned)
cleaned = re.sub(r"[^a-zA-Z0-9]+$", "", cleaned)
if not cleaned:
    cleaned = "admin"
print(cleaned[:50])
PY
)"

  user_json="$(identity_pocket_id_user_create "${username}" "${email}")" || {
    echo "Identity: failed to create first admin user (${email})" >&2
    return 1
  }
  user_id="$(printf '%s\n' "${user_json}" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["id"])')" || {
    echo "Identity: first admin create response missing id" >&2
    return 1
  }
  [[ -n "${user_id}" ]] || {
    echo "Identity: first admin create returned empty id" >&2
    return 1
  }

  token="$(identity_pocket_id_one_time_access_token_create "${user_id}")" || {
    echo "Identity: failed to mint first-admin one-time access token" >&2
    return 1
  }
  login_url="${app_url}/lc/${token}"
  echo "Identity: first-admin one-time login URL (open once to register a passkey):" >&2
  echo "${login_url}" >&2
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
  local admin_env_unchanged=0

  quadlet_user_session_begin

  mkdir -p "${DATA_ROOT}" "${DATA_ROOT}/admin" "${DATA_ROOT}/data"

  if [[ -f "${ADMIN_ENV}" && -f "${staged_admin_env}" ]] && cmp -s "${staged_admin_env}" "${ADMIN_ENV}"; then
    admin_env_unchanged=1
  fi

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

  if [[ "${admin_env_unchanged}" == "1" ]] && identity_pod_already_ready; then
    identity_bootstrap_first_admin || return 1
    return 0
  fi

  identity_stop_pod_gracefully
  identity_clear_stale_app_lock_if_idle
  identity_start_pod
  quadlet_user systemctl --user --quiet is-active identity-pod.service || {
    echo "Identity: identity-pod.service is not active" >&2
    quadlet_user systemctl --user status identity-pod.service identity-pocket-id.service --no-pager >&2 || true
    return 1
  }

  identity_wait_ready || {
    identity_stop_pod_gracefully
    identity_clear_stale_app_lock_if_idle
    identity_start_pod || true
    identity_wait_ready || {
      quadlet_user systemctl --user status identity-pod.service identity-pocket-id.service --no-pager >&2 || true
      return 1
    }
  }

  identity_bootstrap_first_admin || return 1
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
