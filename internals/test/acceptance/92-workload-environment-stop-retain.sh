#!/usr/bin/env bash
# Acceptance Test: Environment Configuration retained on Intent stop
# (ADR-0035 / ADR-0053 / ADR-0054 / #201 / #217). Binding×Requires injects;
# stop retains the Platform User EnvironmentFile tree until Orphan Reap
# (Environment absence), not Intent destroy.
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
WL_KEEP=envkeep
acceptance_wl_track "${WL_STOP}" "${WL_KEEP}"
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
Description=Propraetor Environment Configuration stop-retain probe ${name}

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
stage_wl "${WL_KEEP}" run

for name in "${WL_STOP}" "${WL_KEEP}"; do
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
  || fail "Intent stop must retain unit file until Orphan Reap"
host_ssh "test -f $(env_tree "${WL_STOP}")/environment" \
  || fail "Intent stop must retain EnvironmentFile until Orphan Reap"
pass "Intent stop retains unit file and EnvironmentFile"

# keep stays run
cat >"${FIX_DIR}/${WL_KEEP}/manifest.json" <<EOF
{
  "intent": "run",
  "source": "internal"
}
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL_KEEP}" --env "${ENV_SLUG}"
acceptance_wait_user_unit_active "${WL_KEEP}.service" \
  || fail "run Workload must stay active after stop peer Setup"
host_ssh "test -f $(env_tree "${WL_KEEP}")/environment" \
  || fail "run Workload must retain EnvironmentFile"
pass "Intent stop leaves peer run Workload alone"

pass "Binding×Requires Intent stop retains Environment Configuration until Orphan Reap"
