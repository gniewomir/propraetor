#!/usr/bin/env bash
# Acceptance Test: Mirror upsert/orphan-leave + Orphan Reap (ADR-0041 / #156)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
ENV_SLUG="${PLATFORM_ENV:-test}"
acceptance_wl_track keep-alive gone-soon
trap 'acceptance_wl_cleanup' EXIT

stage_wl() {
  local name="$1"
  mkdir -p "${FIX_DIR}/${name}/quadlets"
  cat >"${FIX_DIR}/${name}/manifest.json" <<EOF
{
  "intent": "stop",
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

host_ssh bash -s <<'REMOTE'
set -euo pipefail
for n in keep-alive gone-soon; do
  rm -rf "/var/lib/host-volume/internals/workloads/${n}"
  rm -f "/home/platform/.config/containers/systemd/${n}.container"
  rm -rf "/home/platform/.config/containers/systemd/${n}.container.d"
done
REMOTE

stage_wl keep-alive
stage_wl gone-soon
"${REPO_ROOT}/internals/ensure-workload.sh" keep-alive --env "${ENV_SLUG}"
"${REPO_ROOT}/internals/ensure-workload.sh" gone-soon --env "${ENV_SLUG}"

host_ssh "mkdir -p /var/lib/host-volume/data/workloads/gone-soon && \
  printf 'durable-orphan\\n' > /var/lib/host-volume/data/workloads/gone-soon/state.bin && \
  chown -R platform:platform /var/lib/host-volume/data/workloads/gone-soon"

host_ssh "test -f /var/lib/host-volume/internals/workloads/gone-soon/manifest.json" \
  || fail "gone-soon should be on Host before orphaning"
host_ssh "test -f /home/platform/.config/containers/systemd/gone-soon.container" \
  || fail "gone-soon unit should be installed before orphaning"

# Drop from Environment → Host leftover becomes an orphan
rm -rf "${FIX_DIR}/gone-soon"

# Mirror upserts keep-alive and must leave the orphan alone
printf '{"intent":"stop","source":"internal","description":"mirrored"}\n' >"${FIX_DIR}/keep-alive/manifest.json"
"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"

host_ssh "grep -Fq mirrored /var/lib/host-volume/internals/workloads/keep-alive/manifest.json" \
  || fail "Mirror must upsert keep-alive Manifest on Host"
host_ssh "test -f /var/lib/host-volume/internals/workloads/gone-soon/manifest.json" \
  || fail "Mirror must leave orphan definition tree alone"
host_ssh "grep -Fxq durable-orphan /var/lib/host-volume/data/workloads/gone-soon/state.bin" \
  || fail "Mirror must leave orphan durable data alone"
pass "Mirror upserts Environment Workloads and leaves orphans alone"

"${REPO_ROOT}/internals/purge-orphans.sh" --env "${ENV_SLUG}"

host_ssh "test ! -e /var/lib/host-volume/internals/workloads/gone-soon" \
  || fail "Orphan Reap must remove orphan definition tree"
host_ssh "test ! -e /var/lib/host-volume/data/workloads/gone-soon" \
  || fail "Orphan Reap must remove orphan durable data"
host_ssh "test ! -e /home/platform/.config/containers/systemd/gone-soon.container" \
  || fail "Orphan Reap must remove orphan unit file"
host_ssh "test -f /var/lib/host-volume/internals/workloads/keep-alive/manifest.json" \
  || fail "Orphan Reap must leave Environment Workloads alone"
pass "Orphan Reap removes absent basenames' Host Volume trees and units"

echo "All Mirror / Orphan Reap Acceptance checks passed."
