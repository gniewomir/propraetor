#!/usr/bin/env bash
# Acceptance Test: Intent trash uninstalls Routes; data retained until Purge (ADR-0024 / ADR-0028)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

HOST="$(acceptance_route_fqdn)"
WL="intent-trash"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
acceptance_wl_track "${WL}" reclaim-intent
trap 'acceptance_wl_cleanup' EXIT

mkdir -p "${FIX_DIR}/${WL}/quadlets"
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
  cat >"${FIX_DIR}/${WL}/routes/${HOST}.conf" <<EOF
location = /trash-probe {
    default_type text/plain;
    return 200 'trash-probe';
}
EOF
fi
cat >"${FIX_DIR}/${WL}/quadlets/${WL}.container" <<EOF
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
  "cat /var/lib/host-volume/data/components/edge/acme/want-list 2>/dev/null || true")"

host_ssh bash -s <<REMOTE
set -euo pipefail
rm -rf /var/lib/host-volume/internals/workloads/${WL} \
  /var/lib/host-volume/internals/workloads/reclaim-intent
rm -f /home/platform/.config/containers/systemd/${WL}.container \
  /home/platform/.config/containers/systemd/reclaim-intent.container
REMOTE

write_manifest run
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${PLATFORM_ENV:-test}"

if [[ -n "${HOST}" ]]; then
  edge_before="$(host_ssh \
    "ls /var/lib/host-volume/data/components/edge/routes/${WL}.conf \
         /var/lib/host-volume/data/components/edge/routes/${WL}--* 2>/dev/null || true")"
  [[ -z "${edge_before}" ]] \
    || fail "Workload Setup alone must not write Edge Route interior (got: ${edge_before})"
  ensure_edge_route_fulfillment
  host_ssh \
    "test -f /var/lib/host-volume/data/components/edge/routes/${WL}--${HOST}.conf" \
    || fail "Edge Setup should fulfill operator Route ${WL}--${HOST}.conf"
else
  echo "SOFT-SKIP: empty Domain want-list — Route install assertions"
fi
host_ssh \
  "test -f /home/platform/.config/containers/systemd/${WL}.container" \
  || fail "Intent run should install authored Quadlet"

write_manifest trash
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${PLATFORM_ENV:-test}"

host_ssh "test -f /var/lib/host-volume/internals/workloads/${WL}/manifest.json" \
  || fail "Intent trash Workload data should remain until Purge"
if [[ -n "${HOST}" ]]; then
  host_ssh \
    "test -f /var/lib/host-volume/internals/workloads/${WL}/routes/${HOST}.conf" \
    || fail "Intent trash should retain Route SoT under Workload tree until Purge"
  still_present="$(host_ssh \
    "ls /var/lib/host-volume/data/components/edge/routes/${WL}.conf /var/lib/host-volume/data/components/edge/routes/${WL}--* 2>/dev/null || true")"
  [[ -n "${still_present}" ]] \
    || fail "Workload Setup alone must not drop Edge Routes on Intent trash"
  ensure_edge_route_fulfillment
fi
host_ssh "test -f /var/lib/host-volume/internals/workloads/${WL}/quadlets/${WL}.container" \
  || fail "Intent trash should retain Quadlet SoT until Purge"
host_ssh "test -f /home/platform/.config/containers/systemd/${WL}.container" \
  || fail "Intent trash should retain unit file until Purge"
trash_routes="$(host_ssh \
  "ls /var/lib/host-volume/data/components/edge/routes/${WL}.conf /var/lib/host-volume/data/components/edge/routes/${WL}--* 2>/dev/null || true")"
[[ -z "${trash_routes}" ]] || fail "Edge Setup must drop fulfillment for Intent trash (got: ${trash_routes})"
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
[[ "${active}" == "inactive" ]] || fail "Intent trash: Workload Quadlet should not be active"
want_after="$(host_ssh \
  "cat /var/lib/host-volume/data/components/edge/acme/want-list 2>/dev/null || true")"
[[ "${want_after}" == "${want_before}" ]] \
  || fail "Intent trash must not rewrite ACME want-list"
pass "Intent trash drops Edge fulfillment via Edge Setup; stops Quadlets; data retained until Purge; want-list unchanged"

mkdir -p "${FIX_DIR}/reclaim-intent"
acceptance_write_artifact_stubs "${FIX_DIR}/reclaim-intent"
cat >"${FIX_DIR}/reclaim-intent/manifest.json" <<EOF
{
  "intent": "run",
  "source": "internal"
}
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "reclaim-intent" --env "${PLATFORM_ENV:-test}"
host_ssh \
  "test -f /var/lib/host-volume/internals/workloads/reclaim-intent/manifest.json" \
  || fail "second Workload Setup with Intent run should succeed"
pass "another Workload can Setup Intent run without hostname claims"
