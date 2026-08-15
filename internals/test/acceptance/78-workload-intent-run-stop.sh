#!/usr/bin/env bash
# Acceptance Test: Intent run with authored Quadlet + operator Route fragment; Intent stop
# (ADR-0024 / ADR-0028). Soft-skips Route attach when Domain want-list is empty.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

HOST="$(acceptance_route_fqdn)"
WL=app
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

mkdir -p "${FIX_DIR}/${WL}/systemd"
acceptance_write_artifact_stubs "${FIX_DIR}/${WL}"
if [[ -n "${HOST}" ]]; then
  mkdir -p "${FIX_DIR}/${WL}/routes"
fi
write_manifest() {
  local intent="$1"
  cat >"${FIX_DIR}/${WL}/manifest.json" <<EOF
{
  "intent": "${intent}",
  "source": "internal"
}
EOF
}
if [[ -n "${HOST}" ]]; then
  cat >"${FIX_DIR}/${WL}/routes/probe.conf" <<EOF
location = /app-route-probe {
    default_type text/plain;
    return 200 'app-route-ok';
}
EOF
  acceptance_bind_route_fragment "${FIX_DIR}/${WL}" "routes/probe.conf" "${HOST}"
fi
cat >"${FIX_DIR}/${WL}/systemd/${WL}.container" <<EOF
[Unit]
Description=Propraetor Workload ${WL}

[Container]
Image=docker.io/library/nginx:1.31.3-alpine
ContainerName=${WL}
Network=service-network.network

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF

want_before="$(host_ssh \
  "cat /host-volume/components/edge/persist/acme/want-list 2>/dev/null || true")"

host_ssh \
  "rm -rf /host-volume/workloads/${WL}; \
   rm -f /home/platform/.config/containers/systemd/workload-${WL} /home/platform/.config/containers/systemd/${WL}.container"

write_manifest run
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${PLATFORM_ENV:-test}"

host_ssh \
  "test -f /host-volume/workloads/${WL}/systemd/${WL}.container" \
  || fail "Intent run should store authored Quadlet SoT"
host_ssh \
  "test -f /home/platform/.config/containers/systemd/workload-${WL}/${WL}.container" \
  || fail "Intent run should install authored Quadlet unit file"
pass "Intent run installs authored Quadlet"

if [[ -n "${HOST}" ]]; then
  edge_before="$(host_ssh \
    "ls /host-volume/components/edge/persist/routes/${WL}.conf \
         /host-volume/components/edge/persist/routes/${WL}--* 2>/dev/null || true")"
  [[ -z "${edge_before}" ]] \
    || fail "Workload Setup alone must not write Edge Route interior (got: ${edge_before})"
  ensure_edge_route_fulfillment
  host_ssh \
    "test -f /host-volume/components/edge/persist/routes/${WL}--${HOST}.conf" \
    || fail "Edge Setup should fulfill Route fragment ${WL}--${HOST}.conf"
  pass "Edge Setup gathers Binding-attached Route fragment after Intent run"
else
  echo "SOFT-SKIP: empty Domain want-list — Route install/stop assertions"
fi

write_manifest stop
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${PLATFORM_ENV:-test}"

if [[ -n "${HOST}" ]]; then
  still_present="$(host_ssh \
    "ls /host-volume/components/edge/persist/routes/${WL}.conf /host-volume/components/edge/persist/routes/${WL}--* 2>/dev/null || true")"
  [[ -n "${still_present}" ]] \
    || fail "Workload Setup alone must not drop Edge Routes on Intent stop"
  ensure_edge_route_fulfillment
  stop_routes="$(host_ssh \
    "ls /host-volume/components/edge/persist/routes/${WL}.conf /host-volume/components/edge/persist/routes/${WL}--* 2>/dev/null || true")"
  [[ -z "${stop_routes}" ]] || fail "Edge Setup must drop fulfillment for Intent stop (got: ${stop_routes})"
  pass "Edge Setup drops Workload Routes after Intent stop"
fi

host_ssh \
  "test -f /home/platform/.config/containers/systemd/workload-${WL}/${WL}.container" \
  || fail "Intent stop should retain unit file until Orphan Reap"
active="$(host_ssh bash -s <<REMOTE
UID_NUM=\$(id -u platform)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
if runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user --quiet is-active ${WL}.service 2>/dev/null; then
  echo active
else
  echo inactive
fi
REMOTE
)"
[[ "${active}" == "inactive" ]] || fail "Intent stop: Workload Quadlet should not be active"
pass "Intent stop: Workload Quadlets are inactive; unit file retained"

want_after="$(host_ssh \
  "cat /host-volume/components/edge/persist/acme/want-list 2>/dev/null || true")"
[[ "${want_after}" == "${want_before}" ]] \
  || fail "Intent stop must not rewrite ACME want-list"
pass "Intent stop leaves Domain ACME want-list unchanged"

if [[ -n "${HOST}" ]]; then
  # Fragment gone; Domain front /healthcheck remains (83). Probe path should miss.
  host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM="\$(id -u platform)"
export XDG_RUNTIME_DIR="/run/user/\${UID_NUM}"
runuser -u platform -- env XDG_RUNTIME_DIR="\$XDG_RUNTIME_DIR" systemctl --user restart edge-pod.service
REMOTE
  code=""
  for _ in $(seq 1 30); do
    code="$(curl -skS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 \
      --resolve "${HOST}:443:${IP}" "https://${HOST}/app-route-probe" 2>/dev/null || true)"
    [[ "${code}" == "404" ]] && break
    sleep 1
  done
  [[ "${code}" == "404" ]] \
    || fail "Intent stop: Route fragment path should miss (HTTP 404), got '${code}'"
  pass "Intent stop: previously attached Route path misses on Domain front"
fi
