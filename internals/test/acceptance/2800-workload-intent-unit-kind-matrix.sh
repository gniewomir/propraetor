#!/usr/bin/env bash
# Acceptance Test: Intent unit-kind matrix — Always-on / On-demand / Ensure (#101 / ADR-0034).
# Ephemeral Workload with Always-on container, On-demand timer+job family (StartWithPod=false),
# and an Ensure volume. Intent stays Workload-wide.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

WL=kind-matrix
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

mkdir -p "${FIX_DIR}/${WL}/systemd" "${FIX_DIR}/${WL}/systemd"
acceptance_write_artifact_stubs "${FIX_DIR}/${WL}"

write_manifest() {
  local intent="$1"
  cat >"${FIX_DIR}/${WL}/manifest.json" <<EOF
{
  "intent": "${intent}",
  "source": "internal"
}
EOF
}

# Always-on long-running container.
cat >"${FIX_DIR}/${WL}/systemd/${WL}.container" <<EOF
[Unit]
Description=Propraetor kind-matrix Always-on

[Container]
Image=docker.io/library/nginx:1.31.3-alpine
ContainerName=${WL}
Network=service-network.network

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF

# On-demand Quadlet job: StartWithPod=false is On-demand, not Always-on.
cat >"${FIX_DIR}/${WL}/systemd/${WL}-batch.container" <<EOF
[Unit]
Description=Propraetor kind-matrix On-demand job container

[Container]
Image=docker.io/library/busybox:latest
ContainerName=${WL}-batch
Exec=echo kind-matrix-batch
StartWithPod=false

[Service]
Type=oneshot

[Install]
WantedBy=default.target
EOF

# Ensure volume — provisioned on run; left in place on stop.
cat >"${FIX_DIR}/${WL}/systemd/${WL}-data.volume" <<EOF
[Volume]
VolumeName=${WL}-data
EOF

# On-demand native timer/job family (shared role stem).
cat >"${FIX_DIR}/${WL}/systemd/${WL}-tick.service" <<EOF
[Unit]
Description=Propraetor kind-matrix On-demand job oneshot

[Service]
Type=oneshot
ExecStart=/bin/true
EOF

cat >"${FIX_DIR}/${WL}/systemd/${WL}-tick.timer" <<EOF
[Unit]
Description=Propraetor kind-matrix On-demand timer

[Timer]
OnBootSec=1h
Unit=${WL}-tick.service

[Install]
WantedBy=timers.target
EOF

unit_state() {
  local unit="$1"
  local prop="$2"
  host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user show -p "${prop}" --value "${unit}" 2>/dev/null || echo ""
REMOTE
}

wait_active() {
  local unit="$1"
  local state=""
  local _
  for _ in $(seq 1 30); do
    state="$(unit_state "${unit}" ActiveState)"
    [[ "${state}" == "active" ]] && return 0
    sleep 1
  done
  return 1
}

volume_exists() {
  host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
if runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c 'cd "\$HOME" && podman volume exists ${WL}-data' 2>/dev/null; then
  echo yes
else
  echo no
fi
REMOTE
}

host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user stop ${WL}-data-volume.service 2>/dev/null || true
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user reset-failed ${WL}-data-volume.service 2>/dev/null || true
rm -rf /host-volume/workloads/${WL}
rm -f /home/platform/.config/containers/systemd/workload-${WL} \
  /home/platform/.config/containers/systemd/${WL}.container \
  /home/platform/.config/containers/systemd/${WL}-batch.container \
  /home/platform/.config/containers/systemd/${WL}-data.volume \
  /home/platform/.config/systemd/user/${WL}-tick.service \
  /home/platform/.config/systemd/user/${WL}-tick.timer \
  /home/platform/.config/systemd/user/timers.target.wants/${WL}-tick.timer
runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c 'cd "\$HOME" && podman volume rm -f ${WL}-data' 2>/dev/null || true
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR systemctl --user daemon-reload
REMOTE

# --- Intent run ---
write_manifest run
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${PLATFORM_ENV:-test}"

host_ssh "test -L /home/platform/.config/containers/systemd/workload-${WL}" \
  || fail "Always-on unit file missing after run"
host_ssh "test -f /home/platform/.config/containers/systemd/workload-${WL}/${WL}-batch.container" \
  || fail "On-demand job container unit file missing after run"
host_ssh "test -f /home/platform/.config/containers/systemd/workload-${WL}/${WL}-data.volume" \
  || fail "Ensure volume unit file missing after run"
host_ssh "test -f /home/platform/.config/systemd/user/${WL}-tick.timer" \
  || fail "On-demand timer unit file missing after run"

wait_active "${WL}.service" \
  || fail "Intent run should start Always-on ${WL}.service (got ActiveState=$(unit_state "${WL}.service" ActiveState))"
pass "Intent run starts Always-on unit"

batch_active="$(unit_state "${WL}-batch.service" ActiveState)"
[[ "${batch_active}" != "active" ]] \
  || fail "Intent run must not start On-demand StartWithPod=false job (ActiveState=${batch_active})"
pass "Intent run leaves StartWithPod=false job installed but not started (Armed)"

timer_enabled="$(unit_state "${WL}-tick.timer" UnitFileState)"
[[ "${timer_enabled}" == "enabled" ]] \
  || fail "Intent run should Arm On-demand timer (UnitFileState=${timer_enabled})"
timer_active="$(unit_state "${WL}-tick.timer" ActiveState)"
[[ "${timer_active}" == "active" ]] \
  || fail "Intent run should leave Armed timer active (ActiveState=${timer_active})"
pass "Intent run Arms On-demand timer"

vol_exists="$(volume_exists)"
[[ "${vol_exists}" == "yes" ]] \
  || fail "Intent run should ensure Ensure volume ${WL}-data exists"
pass "Intent run ensures Ensure volume"

# --- Intent stop ---
write_manifest stop
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${PLATFORM_ENV:-test}"

always_active="$(unit_state "${WL}.service" ActiveState)"
[[ "${always_active}" != "active" ]] \
  || fail "Intent stop should stop Always-on (ActiveState=${always_active})"
pass "Intent stop stops Always-on unit"

batch_active="$(unit_state "${WL}-batch.service" ActiveState)"
[[ "${batch_active}" != "active" ]] \
  || fail "Intent stop should Disarm On-demand job (ActiveState=${batch_active})"
timer_enabled="$(unit_state "${WL}-tick.timer" UnitFileState)"
[[ "${timer_enabled}" != "enabled" ]] \
  || fail "Intent stop should Disarm On-demand timer (UnitFileState=${timer_enabled})"
timer_active="$(unit_state "${WL}-tick.timer" ActiveState)"
[[ "${timer_active}" != "active" ]] \
  || fail "Intent stop should leave Disarmed timer inactive (ActiveState=${timer_active})"
pass "Intent stop Disarms On-demand timer and job"

host_ssh "test -f /home/platform/.config/containers/systemd/workload-${WL}/${WL}-data.volume" \
  || fail "Intent stop must retain Ensure unit file until Orphan Reap"
vol_exists="$(volume_exists)"
[[ "${vol_exists}" == "yes" ]] \
  || fail "Intent stop must leave Ensure volume in place (got exists=${vol_exists})"
pass "Intent stop leaves Ensure resources in place; unit files retained"
