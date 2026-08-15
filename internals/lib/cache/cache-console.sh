#!/usr/bin/env bash
# Cache operator console helpers (ADR-0055 / #226).
# Sourced by ./cache.sh. Not an operator entrypoint.
#
# Public:
#   cache_console_local_port
#     Print a free TCP port on 127.0.0.1.
#   cache_console_cli_base_args LOCAL_PORT CA_FILE CERT_FILE KEY_FILE
#     Print space-safe argv words for valkey-cli TLS dial via the operator tunnel
#     (127.0.0.1 + SNI cache for SAN DNS:cache). One arg per line.
#   cache_console_start_host_loopback_proxy USER_NAME
#     Start Host 127.0.0.1 proxy into cache-valkey netns (rootless CNI is not
#     reachable from Host root). Prints listen port. Writes pid to
#     /tmp/platform-cache-console-proxy.pid on the Host.
#   cache_console_stop_host_loopback_proxy
#     Stop proxy started by cache_console_start_host_loopback_proxy.

_CACHE_CONSOLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CACHE_CONSOLE_HOST_PROXY_PY="${_CACHE_CONSOLE_LIB_DIR}/cache-console-host-proxy.py"

cache_console_local_port() {
  python3 - <<'PY'
import socket

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# Fixed TLS dial shape for the operator tunnel. Fail closed on empty inputs.
cache_console_cli_base_args() {
  local port="${1-}"
  local ca="${2-}"
  local cert="${3-}"
  local key="${4-}"

  if [[ -z "${port}" || -z "${ca}" || -z "${cert}" || -z "${key}" ]]; then
    echo "cache console: local port, CA, cert, and key are required" >&2
    return 1
  fi
  if [[ ! "${port}" =~ ^[0-9]+$ ]] || [[ "${port}" -lt 1 || "${port}" -gt 65535 ]]; then
    echo "cache console: invalid local port '${port}'" >&2
    return 1
  fi

  printf '%s\n' \
    --tls \
    -h 127.0.0.1 \
    -p "${port}" \
    --sni cache \
    --cacert "${ca}" \
    --cert "${cert}" \
    --key "${key}"
}

# Rootless service-network IPs are not reachable from Host root. Proxy via nsenter
# into cache-valkey's netns and listen on Host 127.0.0.1 for SSH -L.
# Requires ambient host_session (host_ssh / host_scp).
cache_console_start_host_loopback_proxy() {
  local user_name="${1:?cache_console_start_host_loopback_proxy: Platform User required}"
  local port remote_script="/tmp/platform-cache-console-proxy.py"

  [[ -f "${_CACHE_CONSOLE_HOST_PROXY_PY}" ]] || {
    echo "cache console: missing ${_CACHE_CONSOLE_HOST_PROXY_PY}" >&2
    return 1
  }

  host_scp "${_CACHE_CONSOLE_HOST_PROXY_PY}" "${remote_script}" </dev/null || return 1

  port="$(
    host_ssh bash -s <<EOF
set -euo pipefail
UID_NUM=\$(id -u ${user_name})
HOME_DIR=\$(getent passwd ${user_name} | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
PID=\$(runuser -u ${user_name} -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c 'cd "\$HOME" && podman inspect -f "{{.State.Pid}}" cache-valkey')
[[ -n "\${PID}" && "\${PID}" != "0" ]] || {
  echo "cache console: cache-valkey pid unavailable" >&2
  exit 1
}
HOST_PORT=\$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
PIDFILE=/tmp/platform-cache-console-proxy.pid
if [[ -f "\${PIDFILE}" ]]; then
  kill "\$(cat "\${PIDFILE}")" 2>/dev/null || true
  rm -f "\${PIDFILE}"
fi
nohup python3 ${remote_script} "\${PID}" "\${HOST_PORT}" "\${PIDFILE}" \
  >/tmp/platform-cache-console-proxy.log 2>&1 &
ready=no
for _ in \$(seq 1 50); do
  if python3 - "\${HOST_PORT}" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket()
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
[[ "\${ready}" == "yes" ]] || {
  echo "cache console: Host loopback proxy failed to listen" >&2
  cat /tmp/platform-cache-console-proxy.log >&2 || true
  exit 1
}
printf '%s\n' "\${HOST_PORT}"
EOF
  )" || return 1
  port="$(printf '%s' "${port}" | tr -d '[:space:]')"
  if [[ -z "${port}" ]]; then
    echo "cache console: empty Host loopback proxy port" >&2
    return 1
  fi
  printf '%s\n' "${port}"
}

cache_console_stop_host_loopback_proxy() {
  host_ssh bash -s <<'EOF' || true
set -euo pipefail
PIDFILE=/tmp/platform-cache-console-proxy.pid
if [[ -f "${PIDFILE}" ]]; then
  kill "$(cat "${PIDFILE}")" 2>/dev/null || true
  rm -f "${PIDFILE}"
fi
rm -f /tmp/platform-cache-console-proxy.py /tmp/platform-cache-console-proxy.log
EOF
}
