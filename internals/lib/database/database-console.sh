#!/usr/bin/env bash
# Database operator console helpers (ADR-0049 / #192).
# Sourced by ./database.sh. Not an operator entrypoint.
#
# Public:
#   database_console_normalize_mode MODE
#     Empty → read. Accepts read|write only; otherwise fail closed.
#   database_console_pgoptions MODE
#     Soft seatbelt for read: -c default_transaction_read_only=on (bypassable).
#     write → empty. Unknown mode fail closed.
#   database_console_local_port
#     Print a free TCP port on 127.0.0.1.
#   database_console_start_host_loopback_proxy USER_NAME
#     Start Host 127.0.0.1 proxy into database-postgres netns (rootless CNI is not
#     reachable from Host root). Prints listen port. Writes pid to
#     /tmp/platform-db-console-proxy.pid on the Host.
#   database_console_stop_host_loopback_proxy
#     Stop proxy started by database_console_start_host_loopback_proxy.

_DB_CONSOLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DB_CONSOLE_HOST_PROXY_PY="${_DB_CONSOLE_LIB_DIR}/database-console-host-proxy.py"

database_console_normalize_mode() {
  local mode="${1-}"
  if [[ -z "${mode}" ]]; then
    printf '%s\n' "read"
    return 0
  fi
  case "${mode}" in
    read | write)
      printf '%s\n' "${mode}"
      return 0
      ;;
    *)
      echo "database console: unknown mode '${mode}' (want read|write)" >&2
      return 1
      ;;
  esac
}

database_console_pgoptions() {
  local mode="${1-}"
  case "${mode}" in
    read)
      printf '%s\n' "-c default_transaction_read_only=on"
      return 0
      ;;
    write)
      printf '%s\n' ""
      return 0
      ;;
    *)
      echo "database console: unknown mode '${mode}' (want read|write)" >&2
      return 1
      ;;
  esac
}

database_console_local_port() {
  python3 - <<'PY'
import socket

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# Rootless service-network IPs are not reachable from Host root. Proxy via nsenter
# into database-postgres's netns and listen on Host 127.0.0.1 for SSH -L.
# Requires ambient host_session (host_ssh / host_scp).
database_console_start_host_loopback_proxy() {
  local user_name="${1:?database_console_start_host_loopback_proxy: Platform User required}"
  local port remote_script="/tmp/platform-db-console-proxy.py"

  [[ -f "${_DB_CONSOLE_HOST_PROXY_PY}" ]] || {
    echo "database console: missing ${_DB_CONSOLE_HOST_PROXY_PY}" >&2
    return 1
  }

  host_scp "${_DB_CONSOLE_HOST_PROXY_PY}" "${remote_script}" </dev/null || return 1

  port="$(
    host_ssh bash -s </dev/null <<EOF
set -euo pipefail
UID_NUM=\$(id -u ${user_name})
HOME_DIR=\$(getent passwd ${user_name} | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
PID=\$(runuser -u ${user_name} -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c 'cd "\$HOME" && podman inspect -f "{{.State.Pid}}" database-postgres')
[[ -n "\${PID}" && "\${PID}" != "0" ]] || {
  echo "database console: database-postgres pid unavailable" >&2
  exit 1
}
HOST_PORT=\$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
PIDFILE=/tmp/platform-db-console-proxy.pid
if [[ -f "\${PIDFILE}" ]]; then
  kill "\$(cat "\${PIDFILE}")" 2>/dev/null || true
  rm -f "\${PIDFILE}"
fi
nohup python3 ${remote_script} "\${PID}" "\${HOST_PORT}" "\${PIDFILE}" \
  >/tmp/platform-db-console-proxy.log 2>&1 &
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
  echo "database console: Host loopback proxy failed to listen" >&2
  cat /tmp/platform-db-console-proxy.log >&2 || true
  exit 1
}
printf '%s\n' "\${HOST_PORT}"
EOF
  )" || return 1
  port="$(printf '%s' "${port}" | tr -d '[:space:]')"
  if [[ -z "${port}" ]]; then
    echo "database console: empty Host loopback proxy port" >&2
    return 1
  fi
  printf '%s\n' "${port}"
}

database_console_stop_host_loopback_proxy() {
  host_ssh bash -s </dev/null <<'EOF' || true
set -euo pipefail
PIDFILE=/tmp/platform-db-console-proxy.pid
if [[ -f "${PIDFILE}" ]]; then
  kill "$(cat "${PIDFILE}")" 2>/dev/null || true
  rm -f "${PIDFILE}"
fi
rm -f /tmp/platform-db-console-proxy.py /tmp/platform-db-console-proxy.log
EOF
}
