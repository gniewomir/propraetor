#!/usr/bin/env bash
# Acceptance Test: Manifest environment retired (ADR-0035 / ADR-0053 / #200).
# Binding×Requires rotate / omit injection is #201.
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
trap 'acceptance_wl_cleanup' EXIT

host_ssh \
  "rm -rf /var/lib/host-volume/internals/workloads/${WL} \
          /home/platform/.config/platform/workloads/${WL}; \
   rm -f /home/platform/.config/containers/systemd/${WL}.container; \
   rm -rf /home/platform/.config/containers/systemd/${WL}.container.d" \
  || true

mkdir -p "${FIX_DIR}/${WL}/quadlets"
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

cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "environment": ["ENVROT_TOKEN", "ENVROT_MODE"]
}
EOF
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>&1; then
  fail "Manifest environment must fail closed (retired; Binding remap is #201)"
fi
pass "retired Manifest environment fails closed"

cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"
acceptance_wait_user_unit_active "${WL}.service" \
  || fail "thin Manifest Setup should start ${WL}.service"
pass "thin Manifest Setup succeeds without Manifest environment"

cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal", "environment": [] }
EOF
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>&1; then
  fail "[] Manifest environment must fail closed (retired key)"
fi
pass "[] Manifest environment fails closed"

pass "Manifest environment retired; rotate/omit injection deferred to Binding"
