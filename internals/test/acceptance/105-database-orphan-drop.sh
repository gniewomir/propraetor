#!/usr/bin/env bash
# Acceptance Test: Orphan Reap → post-workloads drops Database fulfillment (ADR-0049 / ADR-0053 / #191 / #202).
# Orphan Reap removes Host SoT; Database drop runs on the next Component Setup post-workloads.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=dborphan
KEEP=dbkeep
acceptance_wl_track "${WL}" "${KEEP}"
trap 'acceptance_wl_cleanup' EXIT

host_ssh bash -s <<REMOTE
set -euo pipefail
for n in ${WL} ${KEEP}; do
  rm -rf "/host-volume/workloads/\${n}" \
         "/home/platform/.config/platform/workloads/\${n}"
  rm -f "/home/platform/.config/containers/systemd/\${n}"*.container
  rm -rf "/home/platform/.config/containers/systemd/\${n}"*.container.d
done
REMOTE

stage_wl() {
  local name="$1"
  mkdir -p "${FIX_DIR}/${name}/quadlets"
  cat >"${FIX_DIR}/${name}/manifest.json" <<EOF
{
  "intent": "run",
  "source": "internal",
  "description": "Database Orphan Reap drop probe"
}
EOF
  cat >"${FIX_DIR}/${name}/quadlets/${name}.container" <<EOF
[Unit]
Description=Propraetor Database Orphan Reap probe ${name}

[Container]
Image=docker.io/library/postgres:16-alpine
ContainerName=${name}
Network=service-network.network
Entrypoint=/bin/sleep
Exec=infinity

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF
}

stage_wl "${WL}"
acceptance_write_database_claim "${FIX_DIR}/${WL}"
stage_wl "${KEEP}"
acceptance_write_artifact_stubs "${FIX_DIR}/${KEEP}"

"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"
ensure_database_fulfillment
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"
"${REPO_ROOT}/internals/ensure-workload.sh" "${KEEP}" --env "${ENV_SLUG}"

host_ssh "test -f /host-volume/components/database/persist/clients/${WL}/client.crt" \
  || fail "expected durable client cert for orphan candidate after fulfill"
pass "Component Setup fulfilled Database for soon-to-be orphan"

# Drop from Environment → Host leftover becomes an orphan (Mirror leaves it alone).
rm -rf "${FIX_DIR:?}/${WL}"
"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"
host_ssh "test -f /host-volume/workloads/${WL}/manifest.json" \
  || fail "Mirror must leave orphan SoT alone before Orphan Reap"

"${REPO_ROOT}/internals/purge-orphans.sh" --env "${ENV_SLUG}"

host_ssh "test ! -e /host-volume/workloads/${WL}" \
  || fail "Orphan Reap must remove orphan SoT"
host_ssh "test -f /host-volume/components/database/persist/clients/${WL}/client.crt" \
  || fail "Orphan Reap alone must not drop Database client material"

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
  || fail "Orphan Reap alone must not drop Postgres role/database (got '${retain_ok}')"
pass "Orphan Reap alone leaves role, database, and client material"

ensure_database_post_workloads

host_ssh "test ! -e /host-volume/components/database/persist/clients/${WL}" \
  || fail "post-workloads must remove durable client material after Orphan Reap"
host_ssh "test ! -e /home/platform/.config/platform/workloads/${WL}/database" \
  || fail "post-workloads must clear published Database binding after Orphan Reap"
host_ssh "test ! -e /home/platform/.config/containers/systemd/${WL}.container.d/50-platform-database.conf" \
  || fail "post-workloads must clear Database drop-in after Orphan Reap"
host_ssh "test -f /host-volume/workloads/${KEEP}/manifest.json" \
  || fail "post-workloads must leave Environment Workloads alone"

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
  || fail "post-workloads must drop Postgres role and database after Orphan Reap (got '${gone_ok}')"
pass "post-workloads drops Database fulfillment after Orphan Reap"
