#!/usr/bin/env bash
# Acceptance Test: Manifest database is retired; Database gather reads Requires
# (ADR-0049 / ADR-0053 / #189 / #200 / #202). Workload Setup still does not fulfill.
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
Image=docker.io/library/nginx:1.31.3-alpine
ContainerName=${WL}
Network=service-network.network

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF

# --- allowlist: database is retired; unknown keys still rejected ---
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
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
  "source": "internal",
  "database": "true"
}
EOF
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>&1; then
  fail "Manifest database must fail closed (retired key)"
fi
pass "retired Manifest database fails closed"

# ROOT_DB_* on Manifest environment fail closed — environment is retired (#200).
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "environment": ["ROOT_DB_USER"]
}
EOF
err="$(mktemp "${TMPDIR:-/tmp}/dbmanifest-err.XXXXXX")"
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>"${err}"; then
  rm -f "${err}"
  fail "ROOT_DB_USER on Manifest environment must fail closed"
fi
grep -Eqi 'environment|unknown keys|allowlist|ROOT_DB_USER|Database admin|must not list' "${err}" \
  || {
    cat "${err}" >&2
    rm -f "${err}"
    fail "error should mention retired environment / allowlist"
  }
rm -f "${err}"
pass "ROOT_DB_USER on Manifest environment fails closed"

cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "environment": ["ROOT_DB_PASSWORD"]
}
EOF
if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>&1; then
  fail "ROOT_DB_PASSWORD on Manifest environment must fail closed"
fi
pass "ROOT_DB_PASSWORD on Manifest environment fails closed"

# Thin Manifest Setup succeeds and does not fulfill Database (Component owns that).
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "description": "Requires database claimant — Setup must not fulfill Database"
}
EOF
acceptance_write_database_claim "${FIX_DIR}/${WL}"
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"
pass "thin Manifest Setup succeeds with Requires database:true"

# Binding / client material must not appear from Workload Setup alone.
if host_ssh "test -d /home/platform/.config/platform/workloads/${WL}/database"; then
  fail "Workload Setup must not publish Database binding"
fi
if host_ssh "test -d /var/lib/host-volume/data/components/database/clients/${WL}"; then
  fail "Workload Setup must not create Database client material"
fi
pass "Workload Setup does not fulfill Database (no binding / client cert)"
