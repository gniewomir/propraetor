#!/usr/bin/env bash
# Acceptance Test: Environment Configuration rotate / shell-only / omit clear
# via Binding × Requires (ADR-0035 / ADR-0053 / #201).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=envrot
acceptance_wl_track "${WL}"
ENV_FILE="${FIX_DIR}/.env.override"
trap 'rm -f "${ENV_FILE}"; unset ENVROT_TOKEN ENVROT_MODE ENVROT_SURPLUS || true; acceptance_wl_cleanup' EXIT

SECRET1='envrot-secret-one'
SECRET2='envrot-secret-two'
SURPLUS='envrot-surplus-value'

host_ssh \
  "rm -rf /var/lib/host-volume/internals/workloads/${WL} \
          /home/platform/.config/platform/workloads/${WL}; \
   rm -f /home/platform/.config/containers/systemd/${WL}.container; \
   rm -rf /home/platform/.config/containers/systemd/${WL}.container.d" \
  || true

mkdir -p "${FIX_DIR}/${WL}/quadlets"
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal"
}
EOF
cat >"${FIX_DIR}/${WL}/requires.json" <<'EOF'
{
  "environment": {
    "APP_TOKEN": "process token",
    "APP_MODE": "process mode"
  },
  "database": false
}
EOF
cat >"${FIX_DIR}/${WL}/binding.json" <<'EOF'
{
  "environment": {
    "ENVROT_TOKEN": "APP_TOKEN",
    "ENVROT_MODE": "APP_MODE"
  }
}
EOF
printf '{}\n' >"${FIX_DIR}/${WL}/provides.json"
cat >"${FIX_DIR}/${WL}/quadlets/${WL}.container" <<EOF
[Unit]
Description=Propraetor Environment Configuration rotate probe

[Container]
Image=docker.io/library/nginx:1.31.3-alpine
ContainerName=${WL}
Network=service-network.network

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF

# --- shell-only (no .env.override file) ---
rm -f "${ENV_FILE}"
unset ENVROT_TOKEN ENVROT_MODE ENVROT_SURPLUS || true
export ENVROT_TOKEN="${SECRET1}"
export ENVROT_MODE=shell-only
export ENVROT_SURPLUS="${SURPLUS}"

"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"

acceptance_wait_user_unit_active "${WL}.service" \
  || fail "shell-only Setup should start ${WL}.service"
acceptance_assert_container_env "${WL}" APP_TOKEN "${SECRET1}"
acceptance_assert_container_env "${WL}" APP_MODE shell-only
acceptance_assert_container_env_absent "${WL}" ENVROT_SURPLUS
pass "shell-only bag resolves without .env.override; surplus ignored in container process env"

# --- rotation with unchanged SoT ---
export ENVROT_TOKEN="${SECRET2}"
export ENVROT_MODE=rotated
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"
acceptance_wait_user_unit_active "${WL}.service" \
  || fail "rotation re-Setup should keep ${WL}.service active"
acceptance_assert_container_env "${WL}" APP_TOKEN "${SECRET2}"
acceptance_assert_container_env "${WL}" APP_MODE rotated
got="$(acceptance_container_printenv "${WL}" APP_TOKEN)"
[[ "${got}" != *"${SECRET1}"* ]] || fail "old secret must not remain after rotation"
pass "re-Setup rotates Environment Configuration in container process env"

# --- empty Requires environment removes Environment Configuration from process env ---
acceptance_write_artifact_stubs "${FIX_DIR}/${WL}"
unset ENVROT_TOKEN ENVROT_MODE ENVROT_SURPLUS || true
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"

acceptance_wait_user_unit_active "${WL}.service" \
  || fail "omit Setup should keep ${WL}.service active"
acceptance_assert_container_env_absent "${WL}" APP_TOKEN
acceptance_assert_container_env_absent "${WL}" APP_MODE
pass "empty Requires environment clears Environment Configuration from container process env"

# --- re-inject then empty Binding/Requires again ---
cat >"${FIX_DIR}/${WL}/requires.json" <<'EOF'
{
  "environment": { "APP_TOKEN": "process token" },
  "database": false
}
EOF
cat >"${FIX_DIR}/${WL}/binding.json" <<'EOF'
{ "environment": { "ENVROT_TOKEN": "APP_TOKEN" } }
EOF
export ENVROT_TOKEN="${SECRET1}"
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"
acceptance_wait_user_unit_active "${WL}.service" \
  || fail "re-inject Setup should start ${WL}.service"
acceptance_assert_container_env "${WL}" APP_TOKEN "${SECRET1}"

acceptance_write_artifact_stubs "${FIX_DIR}/${WL}"
unset ENVROT_TOKEN || true
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"
acceptance_wait_user_unit_active "${WL}.service" \
  || fail "empty-remap Setup should keep ${WL}.service active"
acceptance_assert_container_env_absent "${WL}" APP_TOKEN
pass "empty Binding remap clears Environment Configuration from container process env"

pass "Environment Configuration rotate / shell-only / omit contract"
