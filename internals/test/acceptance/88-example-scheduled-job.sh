#!/usr/bin/env bash
# Acceptance Test: environments/example scheduled-job teaching Workload (#104 / ADR-0034).
# Materializes the committed example into the active Environment, Setups it, and asserts
# On-demand timer + job family Armed on Intent run and Disarmed on stop / trash.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

WL=scheduled-job
ROLE="batch"
EXAMPLE_SRC="${REPO_ROOT}/environments/example/${WL}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

[[ -d "${EXAMPLE_SRC}" ]] || fail "missing teaching example at environments/example/${WL}"
[[ -f "${EXAMPLE_SRC}/manifest.json" ]] || fail "example missing manifest.json"
[[ -f "${EXAMPLE_SRC}/quadlets/${WL}-${ROLE}.container" ]] \
  || fail "example missing On-demand job ${WL}-${ROLE}.container"
[[ -f "${EXAMPLE_SRC}/systemd/${WL}-${ROLE}.timer" ]] \
  || fail "example missing On-demand timer ${WL}-${ROLE}.timer"

grep -qE '^StartWithPod=false$' "${EXAMPLE_SRC}/quadlets/${WL}-${ROLE}.container" \
  || fail "example job container must set StartWithPod=false (On-demand, not Always-on)"
grep -qE '^PublishPort=' "${EXAMPLE_SRC}/quadlets/${WL}-${ROLE}.container" \
  && fail "example job container must not PublishPort (soft: Workloads publish none)"
grep -qE "^Unit=${WL}-${ROLE}\\.service$" "${EXAMPLE_SRC}/systemd/${WL}-${ROLE}.timer" \
  || fail "example timer must target shared-stem job service ${WL}-${ROLE}.service"
grep -qE '^WantedBy=timers\.target$' "${EXAMPLE_SRC}/systemd/${WL}-${ROLE}.timer" \
  || fail "example timer must WantedBy=timers.target"

# Soft basename habit: timer/job family shares role stem; no Escape Hatch units.
for path in "${EXAMPLE_SRC}/quadlets"/* "${EXAMPLE_SRC}/systemd"/*; do
  [[ -e "${path}" ]] || continue
  base="$(basename "${path}")"
  case "${base}" in
  "${WL}-${ROLE}".*) ;;
  *) fail "example unit ${base} must use shared role stem ${WL}-${ROLE}" ;;
  esac
done

rm -rf "${FIX_DIR:?}/${WL:?}"
cp -R "${EXAMPLE_SRC}" "${FIX_DIR}/${WL}"

write_manifest() {
  local intent="$1"
  cat >"${FIX_DIR}/${WL}/manifest.json" <<EOF
{
  "intent": "${intent}",
  "source": "internal"
}
EOF
}

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

host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user stop ${WL}-${ROLE}.service ${WL}-${ROLE}.timer 2>/dev/null || true
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user disable --now ${WL}-${ROLE}.timer 2>/dev/null || true
rm -rf /var/lib/host-volume/internals/workloads/${WL}
rm -f /home/platform/.config/containers/systemd/${WL}-${ROLE}.container \
  /home/platform/.config/systemd/user/${WL}-${ROLE}.timer \
  /home/platform/.config/systemd/user/timers.target.wants/${WL}-${ROLE}.timer
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR systemctl --user daemon-reload
REMOTE

# --- Intent run: Arm ---
write_manifest run
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${PLATFORM_ENV:-test}"

host_ssh \
  "test -f /var/lib/host-volume/internals/workloads/${WL}/quadlets/${WL}-${ROLE}.container" \
  || fail "Setup should store authored job container SoT"
host_ssh \
  "test -f /var/lib/host-volume/internals/workloads/${WL}/systemd/${WL}-${ROLE}.timer" \
  || fail "Setup should store authored timer SoT"
host_ssh \
  "test -f /home/platform/.config/containers/systemd/${WL}-${ROLE}.container" \
  || fail "Setup should install authored job container"
host_ssh \
  "test -f /home/platform/.config/systemd/user/${WL}-${ROLE}.timer" \
  || fail "Setup should install authored timer"
pass "example scheduled-job Setups cleanly (SoT + Host units)"

job_active="$(unit_state "${WL}-${ROLE}.service" ActiveState)"
[[ "${job_active}" != "active" ]] \
  || fail "Intent run must not start On-demand job payload (ActiveState=${job_active})"
pass "Intent run leaves StartWithPod=false job installed but not started (Armed)"

timer_enabled="$(unit_state "${WL}-${ROLE}.timer" UnitFileState)"
[[ "${timer_enabled}" == "enabled" ]] \
  || fail "Intent run should Arm On-demand timer (UnitFileState=${timer_enabled})"
timer_active="$(unit_state "${WL}-${ROLE}.timer" ActiveState)"
[[ "${timer_active}" == "active" ]] \
  || fail "Intent run should leave Armed timer active (ActiveState=${timer_active})"
pass "Intent run Arms On-demand timer"

# --- Intent stop: Disarm ---
write_manifest stop
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${PLATFORM_ENV:-test}"

job_active="$(unit_state "${WL}-${ROLE}.service" ActiveState)"
[[ "${job_active}" != "active" ]] \
  || fail "Intent stop should Disarm On-demand job (ActiveState=${job_active})"
timer_enabled="$(unit_state "${WL}-${ROLE}.timer" UnitFileState)"
[[ "${timer_enabled}" != "enabled" ]] \
  || fail "Intent stop should Disarm On-demand timer (UnitFileState=${timer_enabled})"
timer_active="$(unit_state "${WL}-${ROLE}.timer" ActiveState)"
[[ "${timer_active}" != "active" ]] \
  || fail "Intent stop should leave Disarmed timer inactive (ActiveState=${timer_active})"
pass "Intent stop Disarms On-demand timer and job"

# --- Intent trash: same Disarm expectation ---
write_manifest trash
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${PLATFORM_ENV:-test}"

job_active="$(unit_state "${WL}-${ROLE}.service" ActiveState)"
[[ "${job_active}" != "active" ]] \
  || fail "Intent trash should Disarm On-demand job (ActiveState=${job_active})"
timer_enabled="$(unit_state "${WL}-${ROLE}.timer" UnitFileState)"
[[ "${timer_enabled}" != "enabled" ]] \
  || fail "Intent trash should Disarm On-demand timer (UnitFileState=${timer_enabled})"
timer_active="$(unit_state "${WL}-${ROLE}.timer" ActiveState)"
[[ "${timer_active}" != "active" ]] \
  || fail "Intent trash should leave Disarmed timer inactive (ActiveState=${timer_active})"
pass "Intent trash Disarms On-demand timer and job"
