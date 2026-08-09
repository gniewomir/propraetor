# Shell twin of terraform/modules/recreatables local.ssh_port (ADR-0030).
# Sourced by operator SSH clients and Acceptance helpers. Keep the digit in sync
# with the Terraform local — mismatch locks the operator out.
# Host-session: bind/open once, then host_ssh / host_scp / host_session_ip.
# Host keys live in environments/<slug>/.ssh/known_hosts — never ~/.ssh/known_hosts.
# shellcheck disable=SC2034  # sourced constant; consumers use PLATFORM_SSH_PORT
PLATFORM_SSH_PORT=9417

# Set when this file is sourced (BASH_SOURCE here is this lib, not the caller).
_PROPRAETOR_LIB_SSH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ambient Host-session state (one session per process).
_HOST_SESSION_IP=""
_HOST_SESSION_PROFILE=""

_propraetor_ssh_repo_root() {
  if [[ -n "${REPO_ROOT:-}" ]]; then
    printf '%s\n' "${REPO_ROOT}"
    return 0
  fi
  printf '%s\n' "$(cd "${_PROPRAETOR_LIB_SSH_DIR}/../.." && pwd)"
}

# Environment-scoped known_hosts path (ADR-0033 dotdir under environments/<slug>/).
# Requires PLATFORM_ENV (environment_activate). Prints path on stdout.
propraetor_ssh_known_hosts_path() {
  local root slug
  root="$(_propraetor_ssh_repo_root)"
  slug="${PLATFORM_ENV:-}"
  if [[ -z "${slug}" ]]; then
    echo "propraetor_ssh_known_hosts_path: PLATFORM_ENV is not set (environment_activate first)" >&2
    return 1
  fi
  printf '%s\n' "${root}/environments/${slug}/.ssh/known_hosts"
}

# Ensure the Environment .ssh dir exists; print known_hosts path.
_propraetor_ssh_prepare_known_hosts() {
  local kh dir
  kh="$(propraetor_ssh_known_hosts_path)" || return 1
  dir="$(dirname "${kh}")"
  mkdir -p "${dir}" || {
    echo "host_session: could not create ${dir}" >&2
    return 1
  }
  chmod 700 "${dir}" 2>/dev/null || true
  printf '%s\n' "${kh}"
}

# Reserved IP survives Host recreate; host keys do not. Clear entries from the
# Environment-scoped store (not ~/.ssh/known_hosts). OpenSSH stores non-22 ports
# as [host]:port — clearing only the bare IP leaves a stale entry that fails
# StrictHostKeyChecking=accept-new (accept-new does not replace mismatches).
# Park calls this after Host identity is gone (ADR-0046); Teardown resets the store.
propraetor_ssh_forget_host() {
  local ip="${1:?propraetor_ssh_forget_host requires IP}"
  local kh
  kh="$(propraetor_ssh_known_hosts_path)" || return 1
  [[ -f "${kh}" ]] || return 0
  ssh-keygen -R "${ip}" -f "${kh}" >/dev/null 2>&1 || true
  ssh-keygen -R "[${ip}]:${PLATFORM_SSH_PORT}" -f "${kh}" >/dev/null 2>&1 || true
  rm -f "${kh}.old"
}

# Drop the whole Environment known_hosts store (Teardown — Reserved IP gone).
propraetor_ssh_known_hosts_reset() {
  local kh
  kh="$(propraetor_ssh_known_hosts_path)" || return 1
  rm -f "${kh}" "${kh}.old"
}

_host_session_validate_profile() {
  case "${1-}" in
    operator | verify) return 0 ;;
    *)
      echo "host_session: unknown profile '${1-}' (use operator|verify)" >&2
      return 1
      ;;
  esac
}

# Bind an ambient Host-session to a known Reserved IP (Acceptance fixture path).
# Profiles: operator | verify (BatchMode). Identity: PROPRAETOR_PRIVATE_KEY_PATH.
host_session_bind() {
  local profile="${1:?host_session_bind requires profile}"
  local ip="${2:?host_session_bind requires IP}"
  _host_session_validate_profile "${profile}" || return 1
  [[ -n "${ip}" ]] || {
    echo "host_session_bind: empty IP" >&2
    return 1
  }
  _HOST_SESSION_PROFILE="${profile}"
  _HOST_SESSION_IP="${ip}"
}

# Open an ambient Host-session from Stack State (terraform output reserved_ip).
# Caller must have environment_activate'd; stack_dir is the Terraform root.
host_session_open() {
  local profile="${1:?host_session_open requires profile}"
  local stack_dir="${2:?host_session_open requires stack_dir}"
  local ip
  _host_session_validate_profile "${profile}" || return 1
  [[ -d "${stack_dir}" ]] || {
    echo "host_session_open: stack_dir is not a directory: ${stack_dir}" >&2
    return 1
  }
  ip="$(
    cd "${stack_dir}" || exit 1
    terraform output -raw reserved_ip 2>/dev/null || true
  )"
  [[ -n "${ip}" ]] || {
    echo "host_session_open: no reserved_ip output (apply the Stack first)" >&2
    return 1
  }
  host_session_bind "${profile}" "${ip}"
}

# Print the bound/opened Reserved IP. Fails closed if no ambient session.
host_session_ip() {
  [[ -n "${_HOST_SESSION_IP}" ]] || {
    echo "host_session_ip: no Host-session (call host_session_open or host_session_bind first)" >&2
    return 1
  }
  printf '%s\n' "${_HOST_SESSION_IP}"
}

# Populate _HOST_SESSION_OPTS from ambient profile. Fails closed if no session.
_host_session_build_opts() {
  local identity="" kh=""
  [[ -n "${_HOST_SESSION_IP}" && -n "${_HOST_SESSION_PROFILE}" ]] || {
    echo "host_session: no Host-session (call host_session_open or host_session_bind first)" >&2
    return 1
  }
  kh="$(_propraetor_ssh_prepare_known_hosts)" || return 1
  _HOST_SESSION_OPTS=(
    -o "Port=${PLATFORM_SSH_PORT}"
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=${kh}"
    -o GlobalKnownHostsFile=/dev/null
  )
  case "${_HOST_SESSION_PROFILE}" in
    verify)
      _HOST_SESSION_OPTS+=(
        -o BatchMode=yes
        -o ConnectTimeout=10
        -o PreferredAuthentications=publickey
      )
      ;;
    operator) ;;
  esac
  identity="${PROPRAETOR_PRIVATE_KEY_PATH:-}"
  if [[ -z "${identity}" ]]; then
    echo "host_session: PROPRAETOR_PRIVATE_KEY_PATH is not set (Operator Configuration)" >&2
    return 1
  fi
  _HOST_SESSION_OPTS+=(-i "${identity}" -o IdentitiesOnly=yes)
}

# Run ssh against the ambient Host-session (payload args only).
host_ssh() {
  _host_session_build_opts || return 1
  ssh "${_HOST_SESSION_OPTS[@]}" "root@${_HOST_SESSION_IP}" "$@"
}

# scp local_path to root@IP:remote_path using the ambient Host-session.
host_scp() {
  local local_path="${1:?host_scp requires local_path}"
  local remote_path="${2:?host_scp requires remote_path}"
  _host_session_build_opts || return 1
  scp "${_HOST_SESSION_OPTS[@]}" "${local_path}" "root@${_HOST_SESSION_IP}:${remote_path}"
}
