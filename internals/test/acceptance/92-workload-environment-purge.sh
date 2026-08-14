#!/usr/bin/env bash
# Acceptance Test: Intent stop/trash retain units; Purge removes trash (ADR-0035 / ADR-0053 / #200).
# Binding×Requires env retain/Purge is #201.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL_STOP=envstop
WL_TRASH=envtrash
WL_KEEP=envkeep
acceptance_wl_track "${WL_STOP}" "${WL_TRASH}" "${WL_KEEP}"
trap 'acceptance_wl_cleanup' EXIT

host_cleanup() {
  local name="$1"
  host_ssh \
    "rm -rf /var/lib/host-volume/internals/workloads/${name} \
            /home/platform/.config/platform/workloads/${name}; \
     rm -f /home/platform/.config/containers/systemd/${name}.container; \
     rm -rf /home/platform/.config/containers/systemd/${name}.container.d" \
    || true
}

host_cleanup "${WL_STOP}"
host_cleanup "${WL_TRASH}"
host_cleanup "${WL_KEEP}"

stage_wl() {
  local name="$1" intent="$2"
  mkdir -p "${FIX_DIR}/${name}/quadlets"
  cat >"${FIX_DIR}/${name}/manifest.json" <<EOF
{
  "intent": "${intent}",
  "source": "internal"
}
EOF
  cat >"${FIX_DIR}/${name}/quadlets/${name}.container" <<EOF
[Unit]
Description=Propraetor Environment Configuration purge probe ${name}

[Container]
Image=docker.io/library/nginx:1.31.3-alpine
ContainerName=${name}
Network=service-network.network

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF
}

stage_wl "${WL_STOP}" run
stage_wl "${WL_TRASH}" run
stage_wl "${WL_KEEP}" run

for name in "${WL_STOP}" "${WL_TRASH}" "${WL_KEEP}"; do
  "${REPO_ROOT}/internals/ensure-workload.sh" "${name}" --env "${ENV_SLUG}"
  acceptance_wait_user_unit_active "${name}.service" \
    || fail "${name} should be active after run Setup"
done
pass "run Setup succeeds with thin Manifest (Binding injection is #201)"

# Intent stop retains env artifacts (Platform User EnvironmentFile tree; unit retained)
cat >"${FIX_DIR}/${WL_STOP}/manifest.json" <<EOF
{
  "intent": "stop",
  "source": "internal"
}
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL_STOP}" --env "${ENV_SLUG}"
host_ssh "test -f /home/platform/.config/containers/systemd/${WL_STOP}.container" \
  || fail "Intent stop must retain unit file until Purge"
pass "Intent stop retains unit file"

# Intent trash retains unit until Purge
cat >"${FIX_DIR}/${WL_TRASH}/manifest.json" <<EOF
{
  "intent": "trash",
  "source": "internal"
}
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL_TRASH}" --env "${ENV_SLUG}"
host_ssh "test -f /home/platform/.config/containers/systemd/${WL_TRASH}.container" \
  || fail "Intent trash must retain unit file until Purge"
pass "Intent trash retains unit file"

# keep-me stays run (for Purge leave-alone check)
cat >"${FIX_DIR}/${WL_KEEP}/manifest.json" <<EOF
{
  "intent": "run",
  "source": "internal"
}
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL_KEEP}" --env "${ENV_SLUG}"

"${REPO_ROOT}/internals/purge-trash.sh" --env "${ENV_SLUG}"

host_ssh "test ! -e /home/platform/.config/containers/systemd/${WL_TRASH}.container" \
  || fail "Purge must remove trash Workload unit"
pass "Purge removes trash Workload unit"

host_ssh "test -f /home/platform/.config/containers/systemd/${WL_STOP}.container" \
  || fail "Purge must leave stop Workload unit file alone"
acceptance_wait_user_unit_active "${WL_KEEP}.service" \
  || fail "Purge must leave run Workload unit active"
pass "Purge leaves run/stop Workloads alone"

pass "thin Manifest stop/trash retain and Purge cleanup contract"
