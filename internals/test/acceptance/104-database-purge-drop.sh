#!/usr/bin/env bash
# Acceptance Test: Intent trash + Purge → post-workloads drops Database fulfillment (ADR-0049 / ADR-0053 / #191 / #202).
# Purge alone must not invoke Component Setup; Deploy/caller composes post-workloads.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=dbpurge
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

host_ssh \
  "rm -rf /host-volume/workloads/${WL} \
          /home/platform/.config/platform/workloads/${WL}; \
   rm -f /home/platform/.config/containers/systemd/${WL}*.container; \
   rm -rf /home/platform/.config/containers/systemd/${WL}*.container.d" \
  || true

write_manifest() {
  local intent="$1"
  cat >"${FIX_DIR}/${WL}/manifest.json" <<EOF
{
  "intent": "${intent}",
  "source": "internal",
  "description": "Database Purge drop probe"
}
EOF
}

mkdir -p "${FIX_DIR}/${WL}/systemd"
write_manifest run
acceptance_write_database_claim "${FIX_DIR}/${WL}"
cat >"${FIX_DIR}/${WL}/systemd/${WL}.container" <<EOF
[Unit]
Description=Propraetor Database Purge drop probe

[Container]
Image=docker.io/library/postgres:16-alpine
ContainerName=${WL}
Network=service-network.network
Entrypoint=/bin/sleep
Exec=infinity

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF

"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"
ensure_database_fulfillment
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"

host_ssh "test -f /home/platform/.config/platform/workloads/${WL}/database/environment" \
  || fail "expected published Database binding after fulfill"
host_ssh "test -f /host-volume/components/database/persist/clients/${WL}/client.crt" \
  || fail "expected durable client cert after fulfill"
pass "Component Setup published Database fulfillment for Intent run"

write_manifest trash
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"
"${REPO_ROOT}/internals/purge-trash.sh" --env "${ENV_SLUG}"

host_ssh "test ! -e /host-volume/workloads/${WL}" \
  || fail "Purge should remove Intent trash SoT"
host_ssh "test -f /host-volume/components/database/persist/clients/${WL}/client.crt" \
  || fail "Purge alone must not drop Database client material"
# Binding may remain under Platform User tree — Purge clears EnvironmentFile only, not Database projection.
host_ssh "test -f /home/platform/.config/platform/workloads/${WL}/database/environment" \
  || fail "Purge alone must not clear Database binding (Component Setup owns drop)"

retain_ok="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
admin=\$(grep -E '^POSTGRES_USER=' /host-volume/components/database/persist/admin/environment \
  | head -n1 | cut -d= -f2-)
[[ -n "\${admin}" ]] || { echo missing-admin; exit 0; }
role=\$(runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c "cd \"\\\$HOME\" && podman exec database-postgres \
    psql -v ON_ERROR_STOP=1 -U \${admin} -d postgres -tAc \
    \\"SELECT 1 FROM pg_roles WHERE rolname = '${WL}'\\"" | tr -d '[:space:]')
db=\$(runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c "cd \"\\\$HOME\" && podman exec database-postgres \
    psql -v ON_ERROR_STOP=1 -U \${admin} -d postgres -tAc \
    \\"SELECT 1 FROM pg_database WHERE datname = '${WL}'\\"" | tr -d '[:space:]')
if [[ "\${role}" == "1" && "\${db}" == "1" ]]; then
  echo yes
else
  echo "no role=\${role} db=\${db}"
fi
REMOTE
)"
[[ "${retain_ok}" == "yes" ]] \
  || fail "Purge alone must not drop Postgres role/database (got '${retain_ok}')"
pass "Purge alone leaves role, database, client material, and binding"

ensure_database_post_workloads

host_ssh "test ! -e /host-volume/components/database/persist/clients/${WL}" \
  || fail "post-workloads must remove durable client material after Purge"
host_ssh "test ! -e /home/platform/.config/platform/workloads/${WL}/database" \
  || fail "post-workloads must clear published Database binding after Purge"
host_ssh "test ! -e /home/platform/.config/containers/systemd/${WL}.container.d/50-platform-database.conf" \
  || fail "post-workloads must clear Database drop-in after Purge"

gone_ok="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
admin=\$(grep -E '^POSTGRES_USER=' /host-volume/components/database/persist/admin/environment \
  | head -n1 | cut -d= -f2-)
[[ -n "\${admin}" ]] || { echo missing-admin; exit 0; }
role=\$(runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c "cd \"\\\$HOME\" && podman exec database-postgres \
    psql -v ON_ERROR_STOP=1 -U \${admin} -d postgres -tAc \
    \\"SELECT 1 FROM pg_roles WHERE rolname = '${WL}'\\"" | tr -d '[:space:]')
db=\$(runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c "cd \"\\\$HOME\" && podman exec database-postgres \
    psql -v ON_ERROR_STOP=1 -U \${admin} -d postgres -tAc \
    \\"SELECT 1 FROM pg_database WHERE datname = '${WL}'\\"" | tr -d '[:space:]')
if [[ -z "\${role}" && -z "\${db}" ]]; then
  echo yes
else
  echo "no role=\${role} db=\${db}"
fi
REMOTE
)"
[[ "${gone_ok}" == "yes" ]] \
  || fail "post-workloads must drop Postgres role and database after Purge (got '${gone_ok}')"
pass "post-workloads drops role, database, client material, and published binding after Purge"
