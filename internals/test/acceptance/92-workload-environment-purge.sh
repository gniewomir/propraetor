#!/usr/bin/env bash
# Acceptance Test: Environment Configuration retained on stop/trash; Purge removes it (ADR-0035 / #123 / #133)
# Outcomes: run injects into container process env; stop/trash retain Platform User env tree;
# Purge removes trash env artifacts and leaves run/stop alone — no drop-in basename probes.
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
ENV_FILE="${FIX_DIR}/.env"
acceptance_env_dotenv_stash
trap 'acceptance_env_dotenv_unstash; unset ENVPURGE_TOKEN || true; acceptance_wl_cleanup' EXIT

SECRET='envpurge-secret-value'

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
  "environment": ["ENVPURGE_TOKEN"]
}
EOF
  cat >"${FIX_DIR}/${name}/quadlets/${name}.container" <<EOF
[Unit]
Description=Propraetor Environment Configuration purge probe ${name}

[Container]
Image=docker.io/library/nginx:alpine
ContainerName=${name}
Network=service-network.network

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF
}

env_tree() {
  printf '/home/platform/.config/platform/workloads/%s\n' "$1"
}

printf 'ENVPURGE_TOKEN=%s\n' "${SECRET}" >"${ENV_FILE}"
export ENVPURGE_TOKEN="${SECRET}"

stage_wl "${WL_STOP}" run
stage_wl "${WL_TRASH}" run
stage_wl "${WL_KEEP}" run

for name in "${WL_STOP}" "${WL_TRASH}" "${WL_KEEP}"; do
  "${REPO_ROOT}/internals/ensure-workload.sh" "${name}" --env "${ENV_SLUG}"
  acceptance_wait_user_unit_active "${name}.service" \
    || fail "${name} should be active after run Setup"
  acceptance_assert_container_env "${name}" ENVPURGE_TOKEN "${SECRET}"
done
pass "run Setup materializes Environment Configuration in container process env"

# Intent stop retains env artifacts (Platform User EnvironmentFile tree; unit retained)
cat >"${FIX_DIR}/${WL_STOP}/manifest.json" <<EOF
{
  "intent": "stop",
  "environment": ["ENVPURGE_TOKEN"]
}
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL_STOP}" --env "${ENV_SLUG}"
host_ssh "test -d $(env_tree "${WL_STOP}")" \
  || fail "Intent stop must retain Platform User Environment Configuration tree"
host_ssh "test -f /home/platform/.config/containers/systemd/${WL_STOP}.container" \
  || fail "Intent stop must retain unit file until Purge"
pass "Intent stop retains Environment Configuration artifacts"

# Intent trash retains env artifacts until Purge
cat >"${FIX_DIR}/${WL_TRASH}/manifest.json" <<EOF
{
  "intent": "trash",
  "environment": ["ENVPURGE_TOKEN"]
}
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL_TRASH}" --env "${ENV_SLUG}"
host_ssh "test -d $(env_tree "${WL_TRASH}")" \
  || fail "Intent trash must retain Platform User Environment Configuration tree until Purge"
host_ssh "test -f /home/platform/.config/containers/systemd/${WL_TRASH}.container" \
  || fail "Intent trash must retain unit file until Purge"
pass "Intent trash retains Environment Configuration artifacts"

# keep-me stays run (for Purge leave-alone check)
cat >"${FIX_DIR}/${WL_KEEP}/manifest.json" <<EOF
{
  "intent": "run",
  "environment": ["ENVPURGE_TOKEN"]
}
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL_KEEP}" --env "${ENV_SLUG}"

"${REPO_ROOT}/internals/purge-trash.sh" --env "${ENV_SLUG}"

host_ssh "test ! -e $(env_tree "${WL_TRASH}")" \
  || fail "Purge must remove trash Workload Environment Configuration tree"
host_ssh "test ! -e /home/platform/.config/containers/systemd/${WL_TRASH}.container" \
  || fail "Purge must remove trash Workload unit"
pass "Purge removes trash Workload Environment Configuration artifacts"

host_ssh "test -d $(env_tree "${WL_STOP}")" \
  || fail "Purge must leave stop Workload Environment Configuration tree alone"
host_ssh "test -d $(env_tree "${WL_KEEP}")" \
  || fail "Purge must leave run Workload Environment Configuration tree alone"
acceptance_wait_user_unit_active "${WL_KEEP}.service" \
  || fail "Purge must leave run Workload unit active"
acceptance_assert_container_env "${WL_KEEP}" ENVPURGE_TOKEN "${SECRET}"
pass "Purge leaves run/stop Workload Environment Configuration alone"

pass "Environment Configuration stop/trash retain and Purge cleanup contract"
