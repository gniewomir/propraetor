#!/usr/bin/env bash
# Acceptance Test: Manifest database allowlist + ROOT_DB_* fail-closed (ADR-0049 / #189).
# Workload Setup accepts boolean database; does not fulfill Database bindings.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=dbmanifest
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

host_ssh \
  "rm -rf /var/lib/host-volume/internals/workloads/${WL} \
          /home/platform/.config/platform/workloads/${WL}; \
   rm -f /home/platform/.config/containers/systemd/${WL}*.container; \
   rm -rf /home/platform/.config/containers/systemd/${WL}*.container.d" \
  || true

mkdir -p "${FIX_DIR}/${WL}/quadlets"
cat >"${FIX_DIR}/${WL}/quadlets/${WL}.container" <<EOF
[Unit]
Description=Propraetor Database Manifest allowlist probe

[Container]
Image=docker.io/library/nginx:alpine
ContainerName=${WL}
Network=service-network.network

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF

# --- allowlist: database accepted; unknown keys still rejected ---
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "database": true,
  "public_hostnames": ["nope.example.test"]
}
EOF
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>&1; then
  fail "Manifest with unknown keys plus database must still fail allowlist"
fi
pass "allowlist still rejects unknown keys alongside database"

cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "database": "true"
}
EOF
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>&1; then
  fail "non-boolean database must fail closed"
fi
pass "non-boolean database fails closed"

# ROOT_DB_* on Manifest environment fail closed (#189) — parse-time, no bag needed.
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "environment": ["ROOT_DB_USER"]
}
EOF
err="$(mktemp "${TMPDIR:-/tmp}/dbmanifest-err.XXXXXX")"
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>"${err}"; then
  rm -f "${err}"
  fail "ROOT_DB_USER on Manifest environment must fail closed"
fi
grep -Eqi 'ROOT_DB_USER|Database admin|fail closed|must not list' "${err}" \
  || {
    cat "${err}" >&2
    rm -f "${err}"
    fail "error should mention ROOT_DB_USER / Database admin"
  }
rm -f "${err}"
pass "ROOT_DB_USER on Manifest environment fails closed"

cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "environment": ["ROOT_DB_PASSWORD"]
}
EOF
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>&1; then
  fail "ROOT_DB_PASSWORD on Manifest environment must fail closed"
fi
pass "ROOT_DB_PASSWORD on Manifest environment fails closed"

# Valid database:true Setup succeeds but does not fulfill Database (Component owns that).
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "database": true,
  "description": "allowlist probe — Setup must not fulfill Database"
}
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"
pass "Manifest database:true is allowlisted by Workload Setup"

# Binding / client material must not appear from Workload Setup alone.
if host_ssh "test -d /home/platform/.config/platform/workloads/${WL}/database"; then
  fail "Workload Setup must not publish Database binding"
fi
if host_ssh "test -d /var/lib/host-volume/data/components/database/clients/${WL}"; then
  fail "Workload Setup must not create Database client material"
fi
pass "Workload Setup does not fulfill Database (no binding / client cert)"
