#!/usr/bin/env bash
# Acceptance Test: environments/example hello-service teaching Workload (#102 / ADR-0034).
# Materializes the committed example into the active Environment, Setups it, and asserts
# Service Network basename reachability, owned Host Volume mount, and no Workload Host ports.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

WL=hello-service
EXAMPLE_SRC="${REPO_ROOT}/environments/example/${WL}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

[[ -d "${EXAMPLE_SRC}" ]] || fail "missing teaching example at environments/example/${WL}"
acceptance_assert_artifact_tree "${EXAMPLE_SRC}" "example ${WL}"
[[ -f "${EXAMPLE_SRC}/systemd/${WL}.pod" ]] || fail "example missing soft-default pod ${WL}.pod"
[[ -f "${EXAMPLE_SRC}/systemd/${WL}-web.container" ]] \
  || fail "example missing member container ${WL}-web.container"

grep -qE '^NetworkAlias=hello-service$' "${EXAMPLE_SRC}/systemd/${WL}.pod" \
  || fail "example pod must set NetworkAlias=${WL}"
grep -qE '^Network=service-network\.network$' "${EXAMPLE_SRC}/systemd/${WL}.pod" \
  || fail "example pod must join Service Network"
grep -qE '^PublishPort=' "${EXAMPLE_SRC}/systemd/${WL}.pod" \
  && fail "example pod must not PublishPort (soft: Workloads publish none)"
grep -qE '^Volume=\.\./persist:/var/lib/workload:rw$' \
  "${EXAMPLE_SRC}/systemd/${WL}-web.container" \
  || fail "example container must mount Persist via ../persist at /var/lib/workload"
grep -qE '^PublishPort=' "${EXAMPLE_SRC}/systemd/${WL}-web.container" \
  && fail "example container must not PublishPort"

rm -rf "${FIX_DIR:?}/${WL:?}"
cp -R "${EXAMPLE_SRC}" "${FIX_DIR}/${WL}"

host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user stop ${WL}-pod.service ${WL}-web.service 2>/dev/null || true
rm -rf /host-volume/workloads/${WL}
rm -f /home/platform/.config/containers/systemd/workload-${WL} \
  /home/platform/.config/containers/systemd/${WL}.pod \
  /home/platform/.config/containers/systemd/${WL}-web.container
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR systemctl --user daemon-reload
REMOTE

"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${PLATFORM_ENV:-test}"

host_ssh \
  "test -f /host-volume/workloads/${WL}/systemd/${WL}.pod" \
  || fail "Setup should store authored pod SoT"
host_ssh \
  "test -f /home/platform/.config/containers/systemd/workload-${WL}/${WL}.pod" \
  || fail "Setup should install authored pod unit via workload dir symlink"
host_ssh \
  "test -f /home/platform/.config/containers/systemd/workload-${WL}/${WL}-web.container" \
  || fail "Setup should install authored member container"
pass "example hello-service Setups cleanly (SoT + Host units)"

wait_active() {
  local unit="$1"
  local state=""
  local _
  for _ in $(seq 1 60); do
    state="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user show -p ActiveState --value ${unit} 2>/dev/null || echo ""
REMOTE
)"
    [[ "${state}" == "active" ]] && return 0
    sleep 1
  done
  return 1
}

wait_active "${WL}-pod.service" \
  || fail "Intent run should start Always-on ${WL}-pod.service"
wait_active "${WL}-web.service" \
  || fail "Intent run should start Always-on ${WL}-web.service"
pass "Always-on pod and member container are active"

# Service Network basename reachability (NetworkAlias=hello-service) from Edge peer.
reach_ok="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
ok=no
for _ in \$(seq 1 30); do
  if runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
    bash -c 'cd "\$HOME" && podman exec systemd-edge-nginx wget -qO- -T 3 http://hello-service/' \
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
  || fail "Service Network should reach Workload by basename hello-service from Edge"
pass "Service Network basename reachability (hello-service from Edge)"

# Owned Host Volume soft scaffold: write inside container, observe on Host tree.
probe_token="hello-owned-$$"
host_ssh env "PROBE_TOKEN=${probe_token}" "WL=${WL}" bash -s <<'REMOTE'
set -euo pipefail
UID_NUM=$(id -u platform)
HOME_DIR=$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/${UID_NUM}
cid=$(runuser -u platform -- env HOME="${HOME_DIR}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_NUM}/bus" \
  bash -c 'cd "$HOME" && podman ps -q --filter name='"${WL}"'-web' | head -n1)
[[ -n "${cid}" ]] || { echo "missing ${WL}-web container" >&2; exit 1; }
runuser -u platform -- env HOME="${HOME_DIR}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_NUM}/bus" \
  PROBE_TOKEN="${PROBE_TOKEN}" \
  bash -c 'cd "$HOME" && printf %s "$PROBE_TOKEN" | podman exec -i '"${cid}"' sh -c "cat >/var/lib/workload/acceptance-owned"'
test -f "/host-volume/workloads/${WL}/persist/acceptance-owned"
grep -qx "${PROBE_TOKEN}" "/host-volume/workloads/${WL}/persist/acceptance-owned"
REMOTE
pass "nested Persist mounted RW at /var/lib/workload"

# No Workload Host ports: installed units must not PublishPort; container has no host bindings.
publish_lines="$(host_ssh \
  "grep -hE '^PublishPort=' /home/platform/.config/containers/systemd/workload-${WL}/${WL}.pod \
     /home/platform/.config/containers/systemd/workload-${WL}/${WL}-web.container 2>/dev/null || true")"
[[ -z "${publish_lines}" ]] \
  || fail "installed hello-service units must not PublishPort (got: ${publish_lines})"
ports_json="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c 'cd "\$HOME" && podman inspect --format "{{json .HostConfig.PortBindings}}" ${WL}-web' 2>/dev/null || echo null
REMOTE
)"
[[ "${ports_json}" == "{}" || "${ports_json}" == "null" || "${ports_json}" == "map[]" ]] \
  || fail "hello-service must not publish Host ports (PortBindings=${ports_json})"
pass "Workload publishes no Host ports"

# Leave Intent stop; local tree cleaned by trap.
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{ "intent": "stop", "source": "internal" }
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${PLATFORM_ENV:-test}"
