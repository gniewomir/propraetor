#!/usr/bin/env bash
# Acceptance Test: Environment Configuration rotate / shell-only / omit clear (ADR-0035 / #122 / #133)
# Outcomes: shell-only and rotation visible in container process env; omit/`[]` clear those keys.
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
ENV_FILE="${FIX_DIR}/.env"
acceptance_env_dotenv_stash
trap 'acceptance_env_dotenv_unstash; unset ENVROT_TOKEN ENVROT_MODE ENVROT_SURPLUS || true; acceptance_wl_cleanup' EXIT

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
  "environment": ["ENVROT_TOKEN", "ENVROT_MODE"]
}
EOF
cat >"${FIX_DIR}/${WL}/quadlets/${WL}.container" <<EOF
[Unit]
Description=Propraetor Environment Configuration rotate probe

[Container]
Image=docker.io/library/nginx:alpine
ContainerName=${WL}
Network=service-network.network

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF

# --- shell-only (no .env file) ---
rm -f "${ENV_FILE}"
unset ENVROT_TOKEN ENVROT_MODE ENVROT_SURPLUS || true
export ENVROT_TOKEN="${SECRET1}"
export ENVROT_MODE=shell-only
export ENVROT_SURPLUS="${SURPLUS}"

"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"

acceptance_wait_user_unit_active "${WL}.service" \
  || fail "shell-only Setup should start ${WL}.service"
acceptance_assert_container_env "${WL}" ENVROT_TOKEN "${SECRET1}"
acceptance_assert_container_env "${WL}" ENVROT_MODE shell-only
acceptance_assert_container_env_absent "${WL}" ENVROT_SURPLUS
pass "shell-only bag resolves without .env; surplus ignored in container process env"

# --- rotation with unchanged SoT ---
export ENVROT_TOKEN="${SECRET2}"
export ENVROT_MODE=rotated
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"
acceptance_wait_user_unit_active "${WL}.service" \
  || fail "rotation re-Setup should keep ${WL}.service active"
acceptance_assert_container_env "${WL}" ENVROT_TOKEN "${SECRET2}"
acceptance_assert_container_env "${WL}" ENVROT_MODE rotated
got="$(acceptance_container_printenv "${WL}" ENVROT_TOKEN)"
[[ "${got}" != *"${SECRET1}"* ]] || fail "old secret must not remain after rotation"
pass "re-Setup rotates Environment Configuration in container process env"

# --- omit removes Environment Configuration from process env ---
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{ "intent": "run" }
EOF
unset ENVROT_TOKEN ENVROT_MODE ENVROT_SURPLUS || true
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"

acceptance_wait_user_unit_active "${WL}.service" \
  || fail "omit Setup should keep ${WL}.service active"
acceptance_assert_container_env_absent "${WL}" ENVROT_TOKEN
acceptance_assert_container_env_absent "${WL}" ENVROT_MODE
pass "omit clears Environment Configuration from container process env"

# --- [] removes after re-inject ---
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "environment": ["ENVROT_TOKEN"]
}
EOF
export ENVROT_TOKEN="${SECRET1}"
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"
acceptance_wait_user_unit_active "${WL}.service" \
  || fail "re-inject Setup should start ${WL}.service"
acceptance_assert_container_env "${WL}" ENVROT_TOKEN "${SECRET1}"

cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{ "intent": "run", "environment": [] }
EOF
unset ENVROT_TOKEN || true
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"
acceptance_wait_user_unit_active "${WL}.service" \
  || fail "[] Setup should keep ${WL}.service active"
acceptance_assert_container_env_absent "${WL}" ENVROT_TOKEN
pass "[] clears Environment Configuration from container process env"

pass "Environment Configuration rotate / shell-only / omit contract"
