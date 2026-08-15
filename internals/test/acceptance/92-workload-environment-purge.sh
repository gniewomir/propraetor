#!/usr/bin/env bash
# Acceptance Test: Environment Configuration retained on stop/trash; Purge removes it
# (ADR-0035 / ADR-0053 / #201). Binding×Requires injects; stop/trash retain the
# Platform User EnvironmentFile tree until Purge.
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
ENV_FILE="${FIX_DIR}/.env.override"
trap 'rm -f "${ENV_FILE}"; unset ENVPURGE_TOKEN || true; acceptance_wl_cleanup' EXIT

SECRET='envpurge-secret-value'

host_cleanup() {
  local name="$1"
  host_ssh \
    "rm -rf /host-volume/workloads/${name} \
            /home/platform/.config/platform/workloads/${name}; \
     rm -f /home/platform/.config/containers/systemd/workload-${name} /home/platform/.config/containers/systemd/${name}.container; \
     rm -rf /home/platform/.config/containers/systemd/${name}.container.d" \
    || true
}

host_cleanup "${WL_STOP}"
host_cleanup "${WL_TRASH}"
host_cleanup "${WL_KEEP}"

stage_wl() {
  local name="$1" intent="$2"
  mkdir -p "${FIX_DIR}/${name}/systemd"
  cat >"${FIX_DIR}/${name}/manifest.json" <<EOF
{
  "intent": "${intent}",
  "source": "internal"
}
EOF
  cat >"${FIX_DIR}/${name}/requires.json" <<'EOF'
{
  "environment": { "APP_TOKEN": "process token" },
  "database": false
}
EOF
  cat >"${FIX_DIR}/${name}/binding.json" <<'EOF'
{ "environment": { "ENVPURGE_TOKEN": "APP_TOKEN" } }
EOF
  printf '{}\n' >"${FIX_DIR}/${name}/provides.json"
  cat >"${FIX_DIR}/${name}/systemd/${name}.container" <<EOF
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
  acceptance_assert_container_env "${name}" APP_TOKEN "${SECRET}"
done
pass "run Setup injects Binding×Requires Environment Configuration"

# Intent stop retains env artifacts (Platform User EnvironmentFile tree; unit retained)
cat >"${FIX_DIR}/${WL_STOP}/manifest.json" <<EOF
{
  "intent": "stop",
  "source": "internal"
}
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL_STOP}" --env "${ENV_SLUG}"
host_ssh "test -f /home/platform/.config/containers/systemd/workload-${WL_STOP}/${WL_STOP}.container" \
  || fail "Intent stop must retain unit file until Purge"
host_ssh "test -f $(env_tree "${WL_STOP}")/environment" \
  || fail "Intent stop must retain EnvironmentFile until Purge"
pass "Intent stop retains unit file and EnvironmentFile"

# Intent trash retains unit and EnvironmentFile until Purge
cat >"${FIX_DIR}/${WL_TRASH}/manifest.json" <<EOF
{
  "intent": "trash",
  "source": "internal"
}
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL_TRASH}" --env "${ENV_SLUG}"
host_ssh "test -f /home/platform/.config/containers/systemd/workload-${WL_TRASH}/${WL_TRASH}.container" \
  || fail "Intent trash must retain unit file until Purge"
host_ssh "test -f $(env_tree "${WL_TRASH}")/environment" \
  || fail "Intent trash must retain EnvironmentFile until Purge"
pass "Intent trash retains unit file and EnvironmentFile"

# keep-me stays run (for Purge leave-alone check)
cat >"${FIX_DIR}/${WL_KEEP}/manifest.json" <<EOF
{
  "intent": "run",
  "source": "internal"
}
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL_KEEP}" --env "${ENV_SLUG}"

"${REPO_ROOT}/internals/purge-trash.sh" --env "${ENV_SLUG}"

host_ssh "test ! -e /home/platform/.config/containers/systemd/workload-${WL_TRASH}" \
  || fail "Purge must remove trash Workload unit"
host_ssh "test ! -e $(env_tree "${WL_TRASH}")/environment" \
  || fail "Purge must remove trash EnvironmentFile"
pass "Purge removes trash Workload unit and EnvironmentFile"

host_ssh "test -f /home/platform/.config/containers/systemd/workload-${WL_STOP}/${WL_STOP}.container" \
  || fail "Purge must leave stop Workload unit file alone"
host_ssh "test -f $(env_tree "${WL_STOP}")/environment" \
  || fail "Purge must leave stop EnvironmentFile alone"
acceptance_wait_user_unit_active "${WL_KEEP}.service" \
  || fail "Purge must leave run Workload unit active"
host_ssh "test -f $(env_tree "${WL_KEEP}")/environment" \
  || fail "Purge must leave run EnvironmentFile alone"
pass "Purge leaves run/stop Workloads alone"

pass "Binding×Requires stop/trash retain and Purge cleanup contract"
