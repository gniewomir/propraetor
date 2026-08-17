#!/usr/bin/env bash
# Acceptance Test: Database Component standing idle with zero claimants (ADR-0049 / #188).
# After Deploy: Postgres up on Service Network dial name database; Host Volume interior
# present; no Host-published Postgres port.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

USER_NAME="${PLATFORM_USER:-platform}"
# Persist interior (ADR-0054): TLS/auth/pgdata under components/database/persist/.
DATA_ROOT=/host-volume/components/database/persist
INTERNALS=/host-volume/components/database
ENV_SLUG="${PLATFORM_ENV:-test}"
ENV_DIR="${REPO_ROOT}/environments/${ENV_SLUG}"

# Standing idle: no Environment Workload Declares Requires database: true.
claimants="$(
  find "${ENV_DIR}" -mindepth 2 -maxdepth 2 -name requires.json -print0 2>/dev/null \
    | xargs -0 grep -l '"database"[[:space:]]*:[[:space:]]*true' 2>/dev/null \
    || true
)"
[[ -z "${claimants}" ]] \
  || fail "expected zero Requires database:true claimants, found: ${claimants}"
pass "no Requires database:true claimants in Environment ${ENV_SLUG}"

must_be_dir() {
  local path="$1"
  host_ssh "test -d '${path}'" || fail "expected directory missing: ${path}"
}

must_be_file() {
  local path="$1"
  host_ssh "test -f '${path}'" || fail "expected file missing: ${path}"
}

must_be_dir "${INTERNALS}"
must_be_file "${INTERNALS}/pre-workloads.sh"
must_be_file "${INTERNALS}/post-workloads.sh"
must_be_file "${INTERNALS}/entrypoint.sh"
must_be_file "${INTERNALS}/systemd/database.pod"
must_be_file "${INTERNALS}/systemd/database-postgres.container"
must_be_dir "${DATA_ROOT}/ca"
must_be_dir "${DATA_ROOT}/server"
must_be_dir "${DATA_ROOT}/pgdata"
must_be_dir "${DATA_ROOT}/clients"
must_be_dir "${DATA_ROOT}/conf"
must_be_file "${DATA_ROOT}/ca/ca.crt"
must_be_file "${DATA_ROOT}/server/server.crt"
must_be_file "${DATA_ROOT}/server/server.key"
must_be_file "${DATA_ROOT}/admin/environment"
must_be_file "${DATA_ROOT}/conf/pg_hba.conf"
pass "Database Component source and Host Volume interior present"

# Authored pod must not publish Host ports (Service Network only).
if host_ssh "grep -E '^PublishPort=' '${INTERNALS}/systemd/database.pod'"; then
  fail "database.pod must not PublishPort (no Host-published Postgres)"
fi
pass "database.pod has no PublishPort"

pod_active="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u ${USER_NAME})
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u ${USER_NAME} -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user show -p ActiveState --value database-pod.service 2>/dev/null || echo ""
REMOTE
)"
[[ "${pod_active}" == "active" ]] || fail "database-pod.service expected active, got '${pod_active}'"
pass "database-pod.service is active (idle standing Component)"

# Dial identity: pg_isready via a throwaway client on the Service Network.
reach_ok="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u ${USER_NAME})
HOME_DIR=\$(getent passwd ${USER_NAME} | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
ok=no
for _ in \$(seq 1 30); do
  if runuser -u ${USER_NAME} -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
    bash -c 'cd "\$HOME" && podman run --rm --network service-network docker.io/library/postgres:16-alpine pg_isready -h database -q' \
    >/dev/null 2>&1; then
    ok=yes
    break
  fi
  sleep 1
done
printf '%s\n' "\${ok}"
REMOTE
)"
[[ "${reach_ok}" == "yes" ]] \
  || fail "Service Network dial name database should answer pg_isready"
pass "Service Network dial name database answers pg_isready"

# No Host port bindings on the Database postgres container.
bindings="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u ${USER_NAME})
HOME_DIR=\$(getent passwd ${USER_NAME} | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u ${USER_NAME} -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c 'cd "\$HOME" && podman inspect --format "{{json .HostConfig.PortBindings}}" database-postgres' 2>/dev/null || echo null
REMOTE
)"
if [[ -n "${bindings}" && "${bindings}" != "null" && "${bindings}" != "{}" && "${bindings}" != "map[]" ]]; then
  fail "database-postgres must not publish Host ports; PortBindings='${bindings}'"
fi
pass "database-postgres has no Host PortBindings"
