#!/usr/bin/env bash
# Acceptance Test: cross-Workload Database isolation (ADR-0049 / ADR-0053 / #190 / #202).
# Two Intent-run Workloads with Requires database:true — A connects with A's cert;
# B cannot access A's database.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WLA=dba
WLB=dbb
acceptance_wl_track "${WLA}" "${WLB}"
trap 'acceptance_wl_cleanup' EXIT

host_ssh \
  "rm -rf /var/lib/host-volume/internals/workloads/${WLA} \
          /var/lib/host-volume/internals/workloads/${WLB} \
          /home/platform/.config/platform/workloads/${WLA} \
          /home/platform/.config/platform/workloads/${WLB}; \
   rm -f /home/platform/.config/containers/systemd/${WLA}*.container \
         /home/platform/.config/containers/systemd/${WLB}*.container; \
   rm -rf /home/platform/.config/containers/systemd/${WLA}*.container.d \
          /home/platform/.config/containers/systemd/${WLB}*.container.d" \
  || true

write_probe_workload() {
  local name="$1"
  mkdir -p "${FIX_DIR}/${name}/quadlets"
  cat >"${FIX_DIR}/${name}/manifest.json" <<EOF
{
  "intent": "run",
  "source": "internal",
  "description": "cross-Workload Database isolation probe (${name})"
}
EOF
  acceptance_write_database_claim "${FIX_DIR}/${name}"
  cat >"${FIX_DIR}/${name}/quadlets/${name}.container" <<EOF
[Unit]
Description=Propraetor Database isolation probe ${name}

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

write_probe_workload "${WLA}"
write_probe_workload "${WLB}"

"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"
ensure_database_fulfillment
"${REPO_ROOT}/internals/ensure-workload.sh" "${WLA}" --env "${ENV_SLUG}"
"${REPO_ROOT}/internals/ensure-workload.sh" "${WLB}" --env "${ENV_SLUG}"

# Wait until both Workloads can run psql with their published bindings.
wait_ssl_self() {
  local wl="$1"
  host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
ok=no
for _ in \$(seq 1 60); do
  if runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
    bash -c 'cd "\$HOME" && systemctl --user --quiet is-active ${wl}.service' \
    >/dev/null 2>&1; then
    out=\$(runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
      DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
      bash -c 'cd "\$HOME" && podman exec ${wl} psql -Atc "SELECT current_user, ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()"' \
      2>/dev/null || true)
    if printf '%s\n' "\${out}" | grep -Eq "^${wl}\\|t\$"; then
      ok=yes
      break
    fi
  fi
  sleep 1
done
printf '%s\n' "\${ok}"
REMOTE
}

a_ok="$(wait_ssl_self "${WLA}")"
[[ "${a_ok}" == "yes" ]] \
  || fail "Workload ${WLA} should connect over SSL with its client cert"
pass "Workload ${WLA} connects to its database with its client cert"

b_ok="$(wait_ssl_self "${WLB}")"
[[ "${b_ok}" == "yes" ]] \
  || fail "Workload ${WLB} should connect over SSL with its client cert"
pass "Workload ${WLB} connects to its database with its client cert"

# B's published env targets B's database; force PGDATABASE=A while keeping B's user+certs.
cross_ok="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
if runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c 'cd "\$HOME" && podman exec -e PGDATABASE=${WLA} ${WLB} \
    psql -Atc "SELECT 1"' >/dev/null 2>&1; then
  echo yes
else
  echo no
fi
REMOTE
)"
[[ "${cross_ok}" == "no" ]] \
  || fail "Workload ${WLB} must not access database ${WLA}"
pass "Workload ${WLB} cannot access Workload ${WLA}'s database"
