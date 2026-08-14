#!/usr/bin/env bash
# Acceptance Test: Manifest environment retired; Source required (ADR-0035 / ADR-0053 / #200).
# Binding×Requires injection is #201.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=envcfg
WL_NC=envcfg-nocontainer
acceptance_wl_track "${WL}" "${WL_NC}"
ENV_FILE="${FIX_DIR}/.env.override"
trap 'rm -f "${ENV_FILE}"; acceptance_wl_cleanup' EXIT

SECRET_OVERRIDE='envcfg-secret-override-value'

host_cleanup_wl() {
  local name="$1"
  host_ssh \
    "rm -rf /var/lib/host-volume/internals/workloads/${name} \
            /home/platform/.config/platform/workloads/${name}; \
     rm -f /home/platform/.config/containers/systemd/${name}*.container; \
     rm -rf /home/platform/.config/containers/systemd/${name}*.container.d" \
    || true
}

host_cleanup_wl "${WL}"
host_cleanup_wl "${WL_NC}"

write_container() {
  local dir="$1"
  local base="$2"
  local cname="$3"
  mkdir -p "${dir}/quadlets"
  cat >"${dir}/quadlets/${base}.container" <<EOF
[Unit]
Description=Propraetor Environment Configuration probe ${base}

[Container]
Image=docker.io/library/nginx:1.31.3-alpine
ContainerName=${cname}
Network=service-network.network

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF
}

# --- allowlist: Source required; environment is retired; unknown keys still rejected ---
mkdir -p "${FIX_DIR}/${WL}/quadlets"
printf 'ENVCFG_TOKEN=x\nENVCFG_MODE=y\n' >"${ENV_FILE}"
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "environment": ["ENVCFG_TOKEN", "ENVCFG_MODE"],
  "public_hostnames": ["nope.example.test"]
}
EOF
write_container "${FIX_DIR}/${WL}" "${WL}" "${WL}"
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>&1; then
  fail "Manifest with unknown keys plus environment must still fail allowlist"
fi
pass "allowlist still rejects unknown keys alongside environment"

cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "environment": ["ENVCFG_TOKEN", "ENVCFG_MODE"]
}
EOF
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>&1; then
  fail "Manifest environment must fail closed (retired; Binding remap is #201)"
fi
pass "retired Manifest environment fails closed"

cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "environment": "ENVCFG_TOKEN"
}
EOF
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>&1; then
  fail "non-array environment must fail closed"
fi
pass "non-array environment fails closed"

cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "environment": ["ENVCFG_TOKEN", ""]
}
EOF
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>&1; then
  fail "empty-string environment key must fail closed"
fi
pass "empty-string environment key fails closed"

# --- non-empty environment without .container fails ---
mkdir -p "${FIX_DIR}/${WL_NC}"
cat >"${FIX_DIR}/${WL_NC}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "environment": ["ENVCFG_TOKEN"]
}
EOF
printf 'ENVCFG_TOKEN=x\n' >"${ENV_FILE}"
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL_NC}" --env "${ENV_SLUG}" >/dev/null 2>&1; then
  fail "non-empty environment without quadlets/*.container must fail closed"
fi
pass "non-empty environment without .container fails closed"

# omit/[] with no containers is fine
cat >"${FIX_DIR}/${WL_NC}/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL_NC}" --env "${ENV_SLUG}"
pass "omit environment with no containers succeeds"

cat >"${FIX_DIR}/${WL_NC}/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal", "environment": [] }
EOF
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL_NC}" --env "${ENV_SLUG}" >/dev/null 2>&1; then
  fail "[] Manifest environment must fail closed (retired key)"
fi
pass "[] Manifest environment fails closed"

# --- invalid dotenv fails ---
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "environment": ["ENVCFG_TOKEN"]
}
EOF
printf 'export ENVCFG_TOKEN=nope\n' >"${ENV_FILE}"
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>&1; then
  fail "invalid dotenv (export) must fail closed"
fi
pass "invalid dotenv fails closed"

# --- missing listed key fails ---
printf 'ENVCFG_MODE=dev\n' >"${ENV_FILE}"
unset ENVCFG_TOKEN ENVCFG_MODE || true
if ENVCFG_MODE=dev "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>&1; then
  fail "missing listed key must fail closed"
fi
# restore manifest keys both required
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "environment": ["ENVCFG_TOKEN", "ENVCFG_MODE"]
}
EOF
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>&1; then
  fail "missing ENVCFG_TOKEN must fail closed"
fi
pass "missing listed key fails closed"

# Binding×Requires injection is #201. Thin Manifest Setup must still succeed.
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "description": "thin Manifest — no Manifest environment"
}
EOF
printf 'ENVCFG_TOKEN=%s\nENVCFG_MODE=baseline\n' "${SECRET_OVERRIDE}" >"${ENV_FILE}"
unset ENVCFG_TOKEN ENVCFG_MODE ENVCFG_SURPLUS || true
export ENVCFG_TOKEN="${SECRET_OVERRIDE}"

"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"

acceptance_wait_user_unit_active "${WL}.service" \
  || fail "Intent run should start ${WL}.service"
pass "thin Manifest Setup succeeds without Manifest environment"

SOT="/var/lib/host-volume/internals/workloads/${WL}"
sot_grep="$(host_ssh "grep -R -F '${SECRET_OVERRIDE}' ${SOT} 2>/dev/null || true")"
[[ -z "${sot_grep}" ]] || fail "secret must not appear in Host Volume SoT (got: ${sot_grep})"
pass "bag values absent from Host Volume SoT"

unset ENVCFG_TOKEN ENVCFG_MODE ENVCFG_SURPLUS || true
pass "Manifest environment retired; thin Manifest Setup contract"
