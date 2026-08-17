#!/usr/bin/env bash
# Acceptance Test: Cache Component standing idle with zero claimants (ADR-0055 / #221).
# After Deploy: Valkey up on Service Network dial name cache; Host Volume interior
# present; no Host-published Cache port.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

USER_NAME="${PLATFORM_USER:-platform}"
# Persist interior (ADR-0054): TLS/ACL/admin under components/cache/persist/.
DATA_ROOT=/host-volume/components/cache/persist
INTERNALS=/host-volume/components/cache
ENV_SLUG="${PLATFORM_ENV:-test}"
ENV_DIR="${REPO_ROOT}/environments/${ENV_SLUG}"

# Standing idle: no Environment Workload Declares Requires cache: true.
claimants="$(
  find "${ENV_DIR}" -mindepth 2 -maxdepth 2 -name requires.json -print0 2>/dev/null \
    | xargs -0 grep -l '"cache"[[:space:]]*:[[:space:]]*true' 2>/dev/null \
    || true
)"
[[ -z "${claimants}" ]] \
  || fail "expected zero Requires cache:true claimants, found: ${claimants}"
pass "no Requires cache:true claimants in Environment ${ENV_SLUG}"

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
must_be_file "${INTERNALS}/systemd/cache.pod"
must_be_file "${INTERNALS}/systemd/cache-valkey.container"
must_be_dir "${DATA_ROOT}/ca"
must_be_dir "${DATA_ROOT}/server"
must_be_dir "${DATA_ROOT}/admin"
must_be_dir "${DATA_ROOT}/conf"
must_be_dir "${DATA_ROOT}/clients"
must_be_file "${DATA_ROOT}/ca/ca.crt"
must_be_file "${DATA_ROOT}/server/server.crt"
must_be_file "${DATA_ROOT}/server/server.key"
must_be_file "${DATA_ROOT}/admin/environment"
must_be_file "${DATA_ROOT}/admin/client.crt"
must_be_file "${DATA_ROOT}/admin/client.key"
must_be_file "${DATA_ROOT}/conf/valkey.conf"
must_be_file "${DATA_ROOT}/conf/users.acl"
# No AOF/RDB keyspace durability under Persist.
if host_ssh "test -e '${DATA_ROOT}/dump.rdb' -o -e '${DATA_ROOT}/appendonly.aof' -o -d '${DATA_ROOT}/data'"; then
  fail "Cache Persist must not hold AOF/RDB keyspace durability"
fi
pass "Cache Component source and Host Volume interior present (no keyspace Persist)"

# Authored pod must not publish Host ports (Service Network only).
if host_ssh "grep -E '^PublishPort=' '${INTERNALS}/systemd/cache.pod'"; then
  fail "cache.pod must not PublishPort (no Host-published Cache)"
fi
pass "cache.pod has no PublishPort"

# ACL default off + admin user present.
acl="$(host_ssh "cat '${DATA_ROOT}/conf/users.acl'")"
printf '%s\n' "${acl}" | grep -Eq '^user default off$' \
  || fail "ACL must disable default user"
printf '%s\n' "${acl}" | grep -Eq '^user .+ on #' \
  || fail "ACL must define admin user with hashed password"
pass "ACL has default off and admin user"

pod_active="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u ${USER_NAME})
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u ${USER_NAME} -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user show -p ActiveState --value cache-pod.service 2>/dev/null || echo ""
REMOTE
)"
[[ "${pod_active}" == "active" ]] || fail "cache-pod.service expected active, got '${pod_active}'"
pass "cache-pod.service is active (idle standing Component)"

# Dial identity: TLS PING via throwaway client on the Service Network using admin material.
reach_ok="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u ${USER_NAME})
HOME_DIR=\$(getent passwd ${USER_NAME} | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
ADMIN_USER=\$(grep -E '^CACHE_ADMIN_USER=' ${DATA_ROOT}/admin/environment | head -n1 | cut -d= -f2-)
ADMIN_PASS=\$(grep -E '^CACHE_ADMIN_PASSWORD=' ${DATA_ROOT}/admin/environment | head -n1 | cut -d= -f2-)
ok=no
for _ in \$(seq 1 30); do
  if runuser -u ${USER_NAME} -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
    ADMIN_USER=\${ADMIN_USER} ADMIN_PASS=\${ADMIN_PASS} \
    bash -c 'cd "\$HOME" && podman run --rm --network service-network \
      -v ${DATA_ROOT}/ca/ca.crt:/certs/ca.crt:ro \
      -v ${DATA_ROOT}/admin/client.crt:/certs/client.crt:ro \
      -v ${DATA_ROOT}/admin/client.key:/certs/client.key:ro \
      -e ADMIN_USER -e ADMIN_PASS \
      docker.io/valkey/valkey:9.1-alpine \
      valkey-cli -h cache --tls \
        --cacert /certs/ca.crt --cert /certs/client.crt --key /certs/client.key \
        --user "\$ADMIN_USER" -a "\$ADMIN_PASS" PING' \
    2>/dev/null | grep -qx PONG; then
    ok=yes
    break
  fi
  sleep 1
done
printf '%s\n' "\${ok}"
REMOTE
)"
[[ "${reach_ok}" == "yes" ]] \
  || fail "Service Network dial name cache should answer TLS PING"
pass "Service Network dial name cache answers TLS PING"

# No Host port bindings on the Cache valkey container.
bindings="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u ${USER_NAME})
HOME_DIR=\$(getent passwd ${USER_NAME} | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u ${USER_NAME} -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c 'cd "\$HOME" && podman inspect --format "{{json .HostConfig.PortBindings}}" cache-valkey' 2>/dev/null || echo null
REMOTE
)"
if [[ -n "${bindings}" && "${bindings}" != "null" && "${bindings}" != "{}" && "${bindings}" != "map[]" ]]; then
  fail "cache-valkey must not publish Host ports; PortBindings='${bindings}'"
fi
pass "cache-valkey has no Host PortBindings"
