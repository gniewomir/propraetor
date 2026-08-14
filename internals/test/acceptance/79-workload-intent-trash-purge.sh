#!/usr/bin/env bash
# Acceptance Test: Intent trash + Purge; Domain-scoped certs survive (ADR-0024 / ADR-0028)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
acceptance_wl_track trash-a reclaim-b keep-me purge-me
trap 'acceptance_wl_cleanup' EXIT

ROUTE_FQDN="$(acceptance_route_fqdn)"

stage_wl() {
  local name="$1" intent="$2"
  mkdir -p "${FIX_DIR}/${name}/quadlets"
  cat >"${FIX_DIR}/${name}/manifest.json" <<EOF
{
  "intent": "${intent}",
  "source": "internal"
}
EOF
  cat >"${FIX_DIR}/${name}/quadlets/${name}.container" <<EOF
[Unit]
Description=Propraetor Workload ${name}

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

write_purge_route() {
  mkdir -p "${FIX_DIR}/purge-me/routes"
  if [[ -n "${ROUTE_FQDN}" ]]; then
    cat >"${FIX_DIR}/purge-me/routes/${ROUTE_FQDN}.conf" <<EOF
location = /purge-probe {
    default_type text/plain;
    return 200 'purge-probe';
}
EOF
  fi
}

stage_wl trash-a run
stage_wl reclaim-b run
stage_wl keep-me stop
stage_wl purge-me run
write_purge_route

want_before="$(host_ssh \
  "cat /var/lib/host-volume/data/components/edge/acme/want-list 2>/dev/null || true")"

host_ssh bash -s <<'REMOTE'
set -euo pipefail
for n in trash-a reclaim-b keep-me purge-me; do
  rm -rf "/var/lib/host-volume/internals/workloads/${n}"
  rm -f "/home/platform/.config/containers/systemd/${n}.container"
done
REMOTE

for name in trash-a keep-me purge-me; do
  stage_wl "${name}" trash
  write_purge_route
  "${REPO_ROOT}/internals/ensure-workload.sh" "${name}" --env "${PLATFORM_ENV:-test}" 2>/dev/null || true
done
"${REPO_ROOT}/internals/purge-trash.sh" --env "${PLATFORM_ENV:-test}"

stage_wl trash-a run
"${REPO_ROOT}/internals/ensure-workload.sh" "trash-a" --env "${PLATFORM_ENV:-test}"
stage_wl trash-a trash
"${REPO_ROOT}/internals/ensure-workload.sh" "trash-a" --env "${PLATFORM_ENV:-test}"

host_ssh "test -f /var/lib/host-volume/internals/workloads/trash-a/manifest.json" \
  || fail "Intent trash Workload data should remain until Purge"
pass "Intent trash retains Workload data until Purge"

stage_wl reclaim-b run
"${REPO_ROOT}/internals/ensure-workload.sh" "reclaim-b" --env "${PLATFORM_ENV:-test}"
host_ssh \
  "test -f /var/lib/host-volume/internals/workloads/reclaim-b/manifest.json" \
  || fail "second Intent run Workload should Setup"
pass "Intent run Workload Setup does not depend on hostname claims"

stage_wl keep-me stop
"${REPO_ROOT}/internals/ensure-workload.sh" "keep-me" --env "${PLATFORM_ENV:-test}"
stage_wl purge-me run
write_purge_route
"${REPO_ROOT}/internals/ensure-workload.sh" "purge-me" --env "${PLATFORM_ENV:-test}"

ROUTE_INSTALLED_NAME=""
if [[ -n "${ROUTE_FQDN}" ]]; then
  ROUTE_INSTALLED_NAME="purge-me--${ROUTE_FQDN}.conf"
  edge_before="$(host_ssh \
    "ls /var/lib/host-volume/data/components/edge/routes/purge-me.conf \
         /var/lib/host-volume/data/components/edge/routes/purge-me--* 2>/dev/null || true")"
  [[ -z "${edge_before}" ]] \
    || fail "Workload Setup alone must not write Edge Route interior (got: ${edge_before})"
  ensure_edge_route_fulfillment
  host_ssh \
    "test -f /var/lib/host-volume/data/components/edge/routes/${ROUTE_INSTALLED_NAME}" \
    || fail "Edge Setup should fulfill operator Route ${ROUTE_INSTALLED_NAME}"
  pass "Edge Setup gathers purge-me Route fragment after Intent run"
else
  echo "SOFT-SKIP: empty Domain want-list — Route install/Purge Route assertions"
fi

# Snapshot Domain-front PEMs (want-list name) — Purge must not delete them.
CERT_FQDN="${ROUTE_FQDN}"
if [[ -z "${CERT_FQDN}" ]]; then
  CERT_FQDN="$(host_ssh \
    "ls -1 /var/lib/host-volume/data/components/edge/certs 2>/dev/null | head -1" || true)"
fi

stage_wl purge-me trash
write_purge_route
"${REPO_ROOT}/internals/ensure-workload.sh" "purge-me" --env "${PLATFORM_ENV:-test}"

if [[ -n "${ROUTE_FQDN}" ]]; then
  host_ssh bash -s <<REMOTE
set -euo pipefail
printf '%s\n' 'leftover-route' > /var/lib/host-volume/data/components/edge/routes/purge-me--${ROUTE_FQDN}.conf
chown platform:platform /var/lib/host-volume/data/components/edge/routes/purge-me--${ROUTE_FQDN}.conf
REMOTE
fi

"${REPO_ROOT}/internals/purge-trash.sh" --env "${PLATFORM_ENV:-test}"

host_ssh "test ! -e /var/lib/host-volume/internals/workloads/purge-me" \
  || fail "Purge should remove Intent trash purge-me SoT"
host_ssh "test ! -e /var/lib/host-volume/data/workloads/purge-me" \
  || fail "Purge should remove Intent trash purge-me durable data"
host_ssh "test ! -e /var/lib/host-volume/internals/workloads/trash-a" \
  || fail "Purge should remove Intent trash trash-a SoT"
host_ssh "test ! -e /var/lib/host-volume/data/workloads/trash-a" \
  || fail "Purge should remove Intent trash trash-a durable data"
if [[ -n "${ROUTE_FQDN}" ]]; then
  leftover="$(host_ssh \
    "ls /var/lib/host-volume/data/components/edge/routes/purge-me.conf /var/lib/host-volume/data/components/edge/routes/purge-me--* 2>/dev/null || true")"
  [[ -n "${leftover}" ]] \
    || fail "Purge alone must not clear Edge Routes (fulfillment drop is Edge Setup)"
  ensure_edge_route_fulfillment
fi
purge_routes="$(host_ssh \
  "ls /var/lib/host-volume/data/components/edge/routes/purge-me.conf /var/lib/host-volume/data/components/edge/routes/purge-me--* 2>/dev/null || true")"
[[ -z "${purge_routes}" ]] || fail "Edge Setup after Purge should drop Routes for trash Workloads (got: ${purge_routes})"
if host_ssh "test -e /home/platform/.config/containers/systemd/purge-me.container"; then
  fail "Purge should remove related Quadlet unit for purge-me"
fi
host_ssh "test -f /var/lib/host-volume/internals/workloads/keep-me/manifest.json" \
  || fail "Purge must not touch Intent stop keep-me"
host_ssh "test -f /var/lib/host-volume/internals/workloads/reclaim-b/manifest.json" \
  || fail "Purge must not touch Intent run reclaim-b"

if [[ -n "${CERT_FQDN}" ]]; then
  host_ssh \
    "test -f /var/lib/host-volume/data/components/edge/certs/${CERT_FQDN}/fullchain.pem \
     && test -f /var/lib/host-volume/data/components/edge/certs/${CERT_FQDN}/privkey.pem" \
    || fail "Purge must keep Domain-scoped certificates for ${CERT_FQDN}"
fi
want_after="$(host_ssh \
  "cat /var/lib/host-volume/data/components/edge/acme/want-list 2>/dev/null || true")"
[[ "${want_after}" == "${want_before}" ]] \
  || fail "Purge must not rewrite ACME want-list"
pass "Purge removes trash Workloads/units; Edge Setup drops Routes; keeps Domain-scoped certs; leaves want-list unchanged"
