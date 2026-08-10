#!/usr/bin/env bash
# Acceptance Test: Intent stop unpublishes Database binding; role/db retained (ADR-0049 / #190).
# Workload Setup alone must not unpublish; Component Setup clears published material;
# Host Volume client cert + Postgres role/database remain until Purge.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=dbstop
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

host_ssh \
  "rm -rf /var/lib/host-volume/internals/workloads/${WL} \
          /home/platform/.config/platform/workloads/${WL}; \
   rm -f /home/platform/.config/containers/systemd/${WL}*.container; \
   rm -rf /home/platform/.config/containers/systemd/${WL}*.container.d" \
  || true

write_manifest() {
  local intent="$1"
  cat >"${FIX_DIR}/${WL}/manifest.json" <<EOF
{
  "intent": "${intent}",
  "database": true,
  "description": "Database Intent stop unpublish probe"
}
EOF
}

mkdir -p "${FIX_DIR}/${WL}/quadlets"
write_manifest run
cat >"${FIX_DIR}/${WL}/quadlets/${WL}.container" <<EOF
[Unit]
Description=Propraetor Database Intent stop probe

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
  || fail "expected published Database environment binding after fulfill"
host_ssh "test -f /home/platform/.config/containers/systemd/${WL}.container.d/50-platform-database.conf" \
  || fail "expected Setup-owned Database drop-in after fulfill"
host_ssh "test -f /var/lib/host-volume/data/components/database/clients/${WL}/client.crt" \
  || fail "expected durable client cert after fulfill"
host_ssh "grep -Eq '^propraetor[[:space:]]+${WL}[[:space:]]+${WL}\$' \
  /var/lib/host-volume/data/components/database/conf/pg_ident.conf" \
  || fail "expected pg_ident map row after fulfill"
pass "Component Setup published binding for Intent run"

write_manifest stop
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"

still_published="$(host_ssh \
  "test -f /home/platform/.config/platform/workloads/${WL}/database/environment && echo yes || echo no")"
[[ "${still_published}" == "yes" ]] \
  || fail "Workload Setup alone must not unpublish Database binding on Intent stop"
pass "Workload Setup alone leaves Database binding published on Intent stop"

ensure_database_fulfillment

host_ssh "test ! -e /home/platform/.config/platform/workloads/${WL}/database" \
  || fail "Component Setup must remove published Database binding on Intent stop"
host_ssh "test ! -e /home/platform/.config/containers/systemd/${WL}.container.d/50-platform-database.conf" \
  || fail "Component Setup must remove Database drop-in on Intent stop"
if host_ssh "grep -Eq '^propraetor[[:space:]]+${WL}[[:space:]]+${WL}\$' \
  /var/lib/host-volume/data/components/database/conf/pg_ident.conf"; then
  fail "Component Setup must remove pg_ident map row on Intent stop"
fi
pass "Component Setup unpublishes Database binding after Intent stop"

host_ssh "test -f /var/lib/host-volume/data/components/database/clients/${WL}/client.crt" \
  || fail "durable client cert must remain until Purge"
pass "durable client material retained after Intent stop"

# Role + database remain (admin local trust inside container; user name only — no secrets).
retain_ok="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
admin=\$(grep -E '^POSTGRES_USER=' /var/lib/host-volume/data/components/database/admin/environment \
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
  || fail "Postgres role and database must remain until Purge (got '${retain_ok}')"
pass "Postgres role and database retained after Intent stop"
