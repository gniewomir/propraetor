#!/usr/bin/env bash
# Interactive Valkey admin console (ADR-0055 / #226).
# Opens an SSH TCP tunnel to Service Network Cache; authenticates with
# Environment-scoped Cache admin credentials (ROOT_CACHE_USER / ROOT_CACHE_PASSWORD)
# and the Persist-owned admin client certificate (CN = admin username).
# No read|write mode split in v1.
#
# Usage: ./cache.sh [--env <slug>] [-- valkey-cli args...]
#   Extra args after flags forward to valkey-cli (Acceptance / scripts).
#   Interactive when no extra args and stdin is a TTY.
#
# Requires: terraform, ssh, valkey-cli; Applied Stack; Operator Configuration private key;
#   Cache admin credentials in environments/<slug>/.env (or shell).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
USER_NAME="${PLATFORM_USER:-platform}"
DATA_ROOT=/host-volume/components/cache/persist
# shellcheck source=internals/lib/cli.sh
source "${REPO_ROOT}/internals/lib/cli.sh"
# shellcheck source=internals/lib/environment/environment.sh
source "${REPO_ROOT}/internals/lib/environment/environment.sh"
# shellcheck source=internals/lib/ssh.sh
source "${REPO_ROOT}/internals/lib/ssh.sh"
# shellcheck source=internals/lib/operator/operator-dotenv.sh
source "${REPO_ROOT}/internals/lib/operator/operator-dotenv.sh"
# shellcheck source=internals/lib/operator/operator-configuration.sh
source "${REPO_ROOT}/internals/lib/operator/operator-configuration.sh"
# shellcheck source=internals/lib/cache/cache-admin-credentials.sh
source "${REPO_ROOT}/internals/lib/cache/cache-admin-credentials.sh"
# shellcheck source=internals/lib/cache/cache-console.sh
source "${REPO_ROOT}/internals/lib/cache/cache-console.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

operator_dotenv_load "${REPO_ROOT}" || exit 1
operator_configuration_require private || exit 1

CLI_env=""
CLI_cli_args=()
cli_operator_parse CLI rest:cli_args -- "$@" || {
  echo "Usage: $0 [--env <slug>] [-- valkey-cli args...]" >&2
  exit 1
}

environment_activate "${STACK_DIR}" "${CLI_env}" || exit 1

command -v terraform >/dev/null || fail "terraform not found"
command -v ssh >/dev/null || fail "ssh not found"
command -v valkey-cli >/dev/null || fail "valkey-cli not found (install a Valkey client)"

STAGE="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/platform-cache-console.XXXXXX")"
CRED_FILE="${STAGE}/admin.env"
CA_FILE="${STAGE}/ca.crt"
CERT_FILE="${STAGE}/client.crt"
KEY_FILE="${STAGE}/client.key"
TUNNEL_PID=""
HOST_PROXY_STARTED=0

cleanup() {
  if [[ -n "${TUNNEL_PID}" ]]; then
    kill "${TUNNEL_PID}" 2>/dev/null || true
    wait "${TUNNEL_PID}" 2>/dev/null || true
  fi
  if [[ "${HOST_PROXY_STARTED}" -eq 1 ]]; then
    cache_console_stop_host_loopback_proxy || true
  fi
  rm -rf "${STAGE}"
}
trap cleanup EXIT

cache_admin_credentials_dotenv_for \
  "$(environments_dir_for "${PLATFORM_ENV}")" \
  "${CRED_FILE}" || exit 1

_line="$(grep -E '^CACHE_ADMIN_USER=' "${CRED_FILE}" | head -n1)" || true
CACHE_ADMIN_USER="${_line#CACHE_ADMIN_USER=}"
_line="$(grep -E '^CACHE_ADMIN_PASSWORD=' "${CRED_FILE}" | head -n1)" || true
CACHE_ADMIN_PASSWORD="${_line#CACHE_ADMIN_PASSWORD=}"
unset _line
[[ -n "${CACHE_ADMIN_USER}" && -n "${CACHE_ADMIN_PASSWORD}" ]] \
  || fail "Cache admin credentials resolve produced empty user/password"

host_session_open operator "${STACK_DIR}" || exit 1

# Host root cannot dial rootless CNI; proxy on Host loopback then SSH -L to it.
# All Host SSH during setup must not consume operator stdin (valkey-cli may be piped).
HOST_PORT="$(cache_console_start_host_loopback_proxy "${USER_NAME}" </dev/null)" || exit 1
HOST_PROXY_STARTED=1
LOCAL_PORT="$(cache_console_local_port)" || fail "could not allocate local TCP port"

host_ssh "cat ${DATA_ROOT}/ca/ca.crt" </dev/null >"${CA_FILE}" \
  || fail "could not fetch Cache CA from Host"
host_ssh "cat ${DATA_ROOT}/admin/client.crt" </dev/null >"${CERT_FILE}" \
  || fail "could not fetch Cache admin client cert from Host"
host_ssh "cat ${DATA_ROOT}/admin/client.key" </dev/null >"${KEY_FILE}" \
  || fail "could not fetch Cache admin client key from Host"
[[ -s "${CA_FILE}" && -s "${CERT_FILE}" && -s "${KEY_FILE}" ]] \
  || fail "Cache TLS material fetched from Host is empty"
chmod 0600 "${KEY_FILE}"

# SSH TCP tunnel: operator localhost → Host 127.0.0.1:HOST_PORT → Valkey netns
host_ssh_client_opts \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -N \
  -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:${HOST_PORT}" \
  </dev/null &
TUNNEL_PID=$!

ready=no
for _ in $(seq 1 50); do
  if ! kill -0 "${TUNNEL_PID}" 2>/dev/null; then
    fail "SSH TCP tunnel exited before becoming ready"
  fi
  if python3 - "${LOCAL_PORT}" <<'PY' 2>/dev/null
import socket, sys
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(0.2)
try:
    s.connect(("127.0.0.1", port))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
PY
  then
    ready=yes
    break
  fi
  sleep 0.1
done
[[ "${ready}" == "yes" ]] || fail "SSH TCP tunnel did not become ready on 127.0.0.1:${LOCAL_PORT}"

# Password via env (not -a) so it stays off argv; never print.
export VALKEYCLI_AUTH="${CACHE_ADMIN_PASSWORD}"
unset CACHE_ADMIN_PASSWORD

# Resolve base TLS argv via helper (also unit-tested); assemble without mapfile (Bash 3.2).
CLI_BASE=()
while IFS= read -r _arg; do
  [[ -n "${_arg}" ]] || continue
  CLI_BASE+=("${_arg}")
done < <(cache_console_cli_base_args \
  "${LOCAL_PORT}" "${CA_FILE}" "${CERT_FILE}" "${KEY_FILE}") || exit 1
[[ "${#CLI_BASE[@]}" -gt 0 ]] || fail "cache console TLS argv empty"

valkey-cli --user "${CACHE_ADMIN_USER}" \
  "${CLI_BASE[@]}" \
  ${CLI_cli_args[@]+"${CLI_cli_args[@]}"}
