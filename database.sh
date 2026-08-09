#!/usr/bin/env bash
# Interactive Postgres console as the Database admin role (ADR-0049 / #192).
# Opens an SSH TCP tunnel to Service Network Postgres; authenticates with
# Environment-scoped Database admin credentials (ROOT_DB_USER / ROOT_DB_PASSWORD).
# No workload/dbname positional in v1 — connects to database "postgres".
#
# Modes: ./database.sh [read|write] [--env <slug>]
#   read (default): soft session default_transaction_read_only=on — bypassable
#     (SET SESSION / transaction / role attributes can clear it; not a hard RO role).
#   write: omits that seatbelt.
#
# Requires: terraform, ssh, psql; Applied Stack; Operator Configuration private key;
#   Database admin credentials in environments/<slug>/.env (or shell).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
USER_NAME="${PLATFORM_USER:-platform}"
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
# shellcheck source=internals/lib/database/database-admin-credentials.sh
source "${REPO_ROOT}/internals/lib/database/database-admin-credentials.sh"
# shellcheck source=internals/lib/database/database-console.sh
source "${REPO_ROOT}/internals/lib/database/database-console.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

operator_dotenv_load "${REPO_ROOT}" || exit 1
operator_configuration_require private || exit 1

CLI_env=""
CLI_mode=""
cli_operator_parse CLI pos:mode:optional -- "$@" || {
  echo "Usage: $0 [read|write] [--env <slug>]" >&2
  exit 1
}

MODE="$(database_console_normalize_mode "${CLI_mode}")" || exit 1
environment_activate "${STACK_DIR}" "${CLI_env}" || exit 1

command -v terraform >/dev/null || fail "terraform not found"
command -v ssh >/dev/null || fail "ssh not found"
command -v psql >/dev/null || fail "psql not found (install a PostgreSQL client)"

STAGE="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/platform-database-console.XXXXXX")"
CRED_FILE="${STAGE}/admin.env"
CA_FILE="${STAGE}/ca.crt"
TUNNEL_PID=""
HOST_PROXY_STARTED=0

cleanup() {
  if [[ -n "${TUNNEL_PID}" ]]; then
    kill "${TUNNEL_PID}" 2>/dev/null || true
    wait "${TUNNEL_PID}" 2>/dev/null || true
  fi
  if [[ "${HOST_PROXY_STARTED}" -eq 1 ]]; then
    database_console_stop_host_loopback_proxy || true
  fi
  rm -rf "${STAGE}"
}
trap cleanup EXIT

database_admin_credentials_dotenv_for \
  "${REPO_ROOT}/environments/${PLATFORM_ENV}" \
  "${CRED_FILE}" || exit 1

_pg_line="$(grep -E '^POSTGRES_USER=' "${CRED_FILE}" | head -n1)" || true
PGUSER="${_pg_line#POSTGRES_USER=}"
_pg_line="$(grep -E '^POSTGRES_PASSWORD=' "${CRED_FILE}" | head -n1)" || true
PGPASSWORD="${_pg_line#POSTGRES_PASSWORD=}"
unset _pg_line
[[ -n "${PGUSER}" && -n "${PGPASSWORD}" ]] \
  || fail "Database admin credentials resolve produced empty user/password"

host_session_open operator "${STACK_DIR}" || exit 1

# Host root cannot dial rootless CNI; proxy on Host loopback then SSH -L to it.
# All Host SSH during setup must not consume operator stdin (psql may be piped).
HOST_PORT="$(database_console_start_host_loopback_proxy "${USER_NAME}" </dev/null)" || exit 1
HOST_PROXY_STARTED=1
LOCAL_PORT="$(database_console_local_port)" || fail "could not allocate local TCP port"

host_ssh "cat /var/lib/host-volume/data/components/database/ca/ca.crt" </dev/null >"${CA_FILE}" \
  || fail "could not fetch Database CA from Host"
[[ -s "${CA_FILE}" ]] || fail "Database CA file empty"

# SSH TCP tunnel: operator localhost → Host 127.0.0.1:HOST_PORT → Postgres netns
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

PGOPTIONS="$(database_console_pgoptions "${MODE}")" || exit 1
export PGUSER PGPASSWORD
export PGHOST=database
export PGHOSTADDR=127.0.0.1
export PGPORT="${LOCAL_PORT}"
export PGDATABASE=postgres
export PGSSLMODE=verify-full
export PGSSLROOTCERT="${CA_FILE}"
if [[ -n "${PGOPTIONS}" ]]; then
  export PGOPTIONS
else
  unset PGOPTIONS || true
fi

if [[ "${MODE}" == "read" ]]; then
  echo "database.sh read: soft default_transaction_read_only=on (bypassable; not a hard RO role)" >&2
fi

# Interactive when stdin is a TTY; otherwise read SQL from stdin (Acceptance / scripts).
psql
