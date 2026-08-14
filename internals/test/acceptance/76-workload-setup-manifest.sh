#!/usr/bin/env bash
# Acceptance Test: thin Manifest (intent + Source) + operator Routes/Quadlets
# (ADR-0024 / ADR-0053 / #57 / ADR-0028 / #200)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
acceptance_wl_track alpha legacy named upstreamed nosource sourced retired-env retired-db zero clash owner-a owner-b
trap 'acceptance_wl_cleanup' EXIT

ROUTE_FQDN="$(acceptance_route_fqdn)"

mkdir -p "${FIX_DIR}/alpha/quadlets"
cat >"${FIX_DIR}/alpha/manifest.json" <<'EOF'
{
  "intent": "run",
  "description": "alpha probe — ignored by automation",
  "source": "internal"
}
EOF
if [[ -n "${ROUTE_FQDN}" ]]; then
  mkdir -p "${FIX_DIR}/alpha/routes"
  cat >"${FIX_DIR}/alpha/routes/${ROUTE_FQDN}.conf" <<EOF
# operator-authored Route fragment for alpha (${ROUTE_FQDN})
location = /alpha-route-probe {
    default_type text/plain;
    return 200 'alpha-route-ok';
}
EOF
fi

mkdir -p "${FIX_DIR}/legacy/routes"
cat >"${FIX_DIR}/legacy/manifest.json" <<'EOF'
{
  "intent": "run",
  "public_hostnames": ["legacy.example.test"]
}
EOF

mkdir -p "${FIX_DIR}/named"
cat >"${FIX_DIR}/named/manifest.json" <<'EOF'
{
  "name": "named",
  "intent": "run"
}
EOF

mkdir -p "${FIX_DIR}/upstreamed"
cat >"${FIX_DIR}/upstreamed/manifest.json" <<'EOF'
{
  "intent": "run",
  "upstream": "upstreamed:8080"
}
EOF

mkdir -p "${FIX_DIR}/nosource"
cat >"${FIX_DIR}/nosource/manifest.json" <<'EOF'
{
  "intent": "run"
}
EOF

mkdir -p "${FIX_DIR}/sourced"
cat >"${FIX_DIR}/sourced/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "https://example.test/bundle.tar"
}
EOF

mkdir -p "${FIX_DIR}/retired-env"
cat >"${FIX_DIR}/retired-env/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "environment": ["ENV_KEY"]
}
EOF

mkdir -p "${FIX_DIR}/retired-db"
cat >"${FIX_DIR}/retired-db/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "database": true
}
EOF

mkdir -p "${FIX_DIR}/zero"
cat >"${FIX_DIR}/zero/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal"
}
EOF

mkdir -p "${FIX_DIR}/clash/quadlets"
cat >"${FIX_DIR}/clash/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal"
}
EOF
# Collide with Component unit basename already on the Host.
cat >"${FIX_DIR}/clash/quadlets/edge-nginx.container" <<'EOF'
[Unit]
Description=clash should fail

[Container]
Image=docker.io/library/nginx:1.31.3-alpine
ContainerName=clash
Network=service-network.network

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF

mkdir -p "${FIX_DIR}/owner-a/quadlets" "${FIX_DIR}/owner-b/quadlets"
cat >"${FIX_DIR}/owner-a/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
cat >"${FIX_DIR}/owner-b/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
cat >"${FIX_DIR}/owner-a/quadlets/shared-name.container" <<'EOF'
[Unit]
Description=owner-a claims shared-name

[Container]
Image=docker.io/library/nginx:1.31.3-alpine
ContainerName=shared-name-a
Network=service-network.network

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF
cp "${FIX_DIR}/owner-a/quadlets/shared-name.container" "${FIX_DIR}/owner-b/quadlets/shared-name.container"

# Snapshot Domain want-list (must not change across Workload Setup).
want_before="$(host_ssh \
  "cat /var/lib/host-volume/data/components/edge/acme/want-list 2>/dev/null || true")"

# Clean durable leftovers
host_ssh \
  "rm -rf /var/lib/host-volume/internals/workloads/alpha \
          /var/lib/host-volume/internals/workloads/legacy \
          /var/lib/host-volume/internals/workloads/named \
          /var/lib/host-volume/internals/workloads/upstreamed \
          /var/lib/host-volume/internals/workloads/nosource \
          /var/lib/host-volume/internals/workloads/sourced \
          /var/lib/host-volume/internals/workloads/retired-env \
          /var/lib/host-volume/internals/workloads/retired-db \
          /var/lib/host-volume/internals/workloads/zero \
          /var/lib/host-volume/internals/workloads/clash \
          /var/lib/host-volume/internals/workloads/owner-a \
          /var/lib/host-volume/internals/workloads/owner-b; \
   rm -f /home/platform/.config/containers/systemd/alpha.container \
         /home/platform/.config/containers/systemd/zero.container \
         /home/platform/.config/containers/systemd/legacy.container \
         /home/platform/.config/containers/systemd/shared-name.container"

"${REPO_ROOT}/internals/ensure-workload.sh" "alpha" --env "${PLATFORM_ENV:-test}"

if [[ -n "${ROUTE_FQDN}" ]]; then
  sot="$(host_ssh \
    "cat /var/lib/host-volume/internals/workloads/alpha/routes/${ROUTE_FQDN}.conf")"
  echo "${sot}" | grep -q 'operator-authored Route fragment for alpha' \
    || fail "Route SoT not stored under workloads/alpha/routes/"
  edge_before="$(host_ssh \
    "ls /var/lib/host-volume/data/components/edge/routes/alpha.conf \
         /var/lib/host-volume/data/components/edge/routes/alpha--* 2>/dev/null || true")"
  [[ -z "${edge_before}" ]] \
    || fail "Workload Setup alone must not write Edge Route interior (got: ${edge_before})"
  pass "Workload Setup syncs Route SoT only; Edge interior unchanged"
  ensure_edge_route_fulfillment
  installed="$(host_ssh \
    "cat /var/lib/host-volume/data/components/edge/routes/alpha--${ROUTE_FQDN}.conf")"
  [[ "${installed}" == "${sot}" ]] || fail "installed Route bytes must match operator SoT"
  echo "${installed}" | grep -q 'Generated by Propraetor' \
    && fail "Propraetor must not generate Route shells" || true
  pass "Edge Setup gathers operator Route fragment; thin Manifest; no invented Quadlet"
else
  echo "SOFT-SKIP: empty Domain want-list — Route install assertions (ADR-0028)"
fi

! host_ssh "test -f /var/lib/host-volume/internals/workloads/alpha/interior.conf" \
  || fail "interior.conf must not be stored"
# No Propraetor-minted Quadlet when quadlets/ is empty.
alpha_units="$(host_ssh \
  "ls /home/platform/.config/containers/systemd/alpha.container 2>/dev/null || true")"
[[ -z "${alpha_units}" ]] || fail "empty quadlets/ must not invent a Quadlet (got: ${alpha_units})"
pass "thin Manifest; no invented Quadlet"

want_after="$(host_ssh \
  "cat /var/lib/host-volume/data/components/edge/acme/want-list 2>/dev/null || true")"
[[ "${want_after}" == "${want_before}" ]] \
  || fail "Workload Setup must not rewrite ACME want-list (before='${want_before}' after='${want_after}')"
pass "Workload Setup leaves Domain ACME want-list unchanged"

reject_thick() {
  local label="$1"
  local name="$2"
  local needle="$3"
  set +e
  "${REPO_ROOT}/internals/ensure-workload.sh" "${name}" --env "${PLATFORM_ENV:-test}" >/tmp/thick-setup.out 2>&1
  local rc=$?
  set -e
  [[ ${rc} -ne 0 ]] || fail "expected failure for ${label}"
  grep -qi "${needle}" /tmp/thick-setup.out \
    || fail "${label} rejection did not mention ${needle} (output: $(cat /tmp/thick-setup.out))"
}

reject_thick "public_hostnames" "legacy" "public_hostnames\|unknown keys\|allowlist"
reject_thick "name" "named" "name\|unknown keys\|allowlist"
reject_thick "upstream" "upstreamed" "upstream\|unknown keys\|allowlist"
reject_thick "missing Source" "nosource" "source is required\|manifest.source"
reject_thick "invalid Source" "sourced" "source\|zip"
reject_thick "retired environment" "retired-env" "environment\|unknown keys\|allowlist"
reject_thick "retired database" "retired-db" "database\|unknown keys\|allowlist"
pass "Workload Setup requires Source and rejects retired Manifest keys (ADR-0024 / ADR-0053)"

"${REPO_ROOT}/internals/ensure-workload.sh" "zero" --env "${PLATFORM_ENV:-test}"
zero_installed="$(host_ssh \
  "ls /var/lib/host-volume/data/components/edge/routes/zero--* 2>/dev/null || true")"
[[ -z "${zero_installed}" ]] || fail "zero-Route Workload must not install Edge Route files (got: ${zero_installed})"
host_ssh "test -f /var/lib/host-volume/internals/workloads/zero/manifest.json" \
  || fail "zero-Route Workload Manifest should still be stored"
pass "Workload Setup succeeds with Intent run and no routes/ directory"

set +e
"${REPO_ROOT}/internals/ensure-workload.sh" "clash" --env "${PLATFORM_ENV:-test}" >/tmp/clash-setup.out 2>&1
clash_rc=$?
set -e
[[ ${clash_rc} -ne 0 ]] || fail "expected failure when quadlet basename collides with Component unit"
grep -qi 'edge-nginx\|already exists\|not owned' /tmp/clash-setup.out \
  || fail "collision rejection unclear (output: $(cat /tmp/clash-setup.out))"
pass "Workload Setup refuses unit basename colliding with Component unit"

"${REPO_ROOT}/internals/ensure-workload.sh" "owner-a" --env "${PLATFORM_ENV:-test}"
set +e
"${REPO_ROOT}/internals/ensure-workload.sh" "owner-b" --env "${PLATFORM_ENV:-test}" >/tmp/owner-b-setup.out 2>&1
owner_b_rc=$?
set -e
[[ ${owner_b_rc} -ne 0 ]] || fail "expected failure when second Workload claims same quadlet basename"
grep -qi 'shared-name\|already exists\|not owned' /tmp/owner-b-setup.out \
  || fail "cross-Workload collision unclear (output: $(cat /tmp/owner-b-setup.out))"
pass "Workload Setup refuses Quadlet basename claimed by another Workload"
