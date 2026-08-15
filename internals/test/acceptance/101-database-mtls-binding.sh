#!/usr/bin/env bash
# Acceptance Test: one Workload passwordless mTLS Database binding (ADR-0049 / ADR-0053 / #189 / #202).
# Intent-run + Requires database:true → role/db/client cert + published binding; connect verify-full.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=dbmtls
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

host_ssh \
  "rm -rf /host-volume/workloads/${WL} \
          /home/platform/.config/platform/workloads/${WL}; \
   rm -f /home/platform/.config/containers/systemd/${WL}*.container; \
   rm -rf /home/platform/.config/containers/systemd/${WL}*.container.d" \
  || true

mkdir -p "${FIX_DIR}/${WL}/systemd"
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "description": "passwordless mTLS Database probe"
}
EOF
acceptance_write_database_claim "${FIX_DIR}/${WL}"
cat >"${FIX_DIR}/${WL}/systemd/${WL}.container" <<EOF
[Unit]
Description=Propraetor Database mTLS probe

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

# Mirror SoT first so pre-workloads gather sees the Declaration (ADR-0041 / ADR-0049).
"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"
ensure_database_fulfillment

# Published binding + client material from Component Setup.
host_ssh "test -f /home/platform/.config/platform/workloads/${WL}/database/environment" \
  || fail "expected published Database environment binding"
host_ssh "test -f /home/platform/.config/platform/workloads/${WL}/database/client.crt" \
  || fail "expected published client.crt"
host_ssh "test -f /host-volume/components/database/persist/clients/${WL}/client.crt" \
  || fail "expected Host Volume client cert"
host_ssh "grep -E '^propraetor[[:space:]]+${WL}[[:space:]]+${WL}\$' \
  /host-volume/components/database/persist/conf/pg_ident.conf" \
  || fail "expected pg_ident map row for ${WL}"
pass "Component Setup created client material and published binding"

# Workload Setup picks up Setup-owned drop-in on start.
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"

# Wait for Always-on unit, then passwordless verify-full connect as basename role.
# Assert ssl is on for the session (verify-full path), not merely that psql works.
connect_ok="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
ok=no
for _ in \$(seq 1 60); do
  if runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
    bash -c 'cd "\$HOME" && systemctl --user --quiet is-active ${WL}.service' \
    >/dev/null 2>&1; then
    out=\$(runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
      DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
      bash -c 'cd "\$HOME" && podman exec ${WL} psql -Atc "SELECT current_user, ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()"' \
      2>/dev/null || true)
    if printf '%s\n' "\${out}" | grep -Eq "^${WL}\\|t\$"; then
      ok=yes
      break
    fi
  fi
  sleep 1
done
printf '%s\n' "\${ok}"
REMOTE
)"
[[ "${connect_ok}" == "yes" ]] \
  || fail "Workload ${WL} should connect over SSL with client cert (verify-full)"
pass "Workload connects to Database with client cert (verify-full)"
