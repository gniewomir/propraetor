#!/usr/bin/env bash
# Acceptance Test: Intent stop unpublishes Cache binding + disables ACL user (ADR-0055 / #224).
# Workload Setup alone must not unpublish; Component Setup clears published material and
# sets ACL user off; Host Volume client cert remains until Orphan Reap (#225).
# Re-run with Intent run re-enables/publishes idempotently.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=cachestop
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

host_ssh \
  "rm -rf /host-volume/workloads/${WL} \
          /home/platform/.config/platform/workloads/${WL}; \
   rm -f /home/platform/.config/containers/systemd/${WL}*.container; \
   rm -rf /home/platform/.config/containers/systemd/${WL}*.container.d" \
  || true

write_manifest() {
  local intent="$1"
  cat >"${FIX_DIR}/${WL}/manifest.json" <<EOF
{
  "intent": "${intent}",
  "source": "internal",
  "description": "Cache Intent stop unpublish probe"
}
EOF
}

mkdir -p "${FIX_DIR}/${WL}/systemd"
write_manifest run
acceptance_write_cache_claim "${FIX_DIR}/${WL}"
cat >"${FIX_DIR}/${WL}/systemd/${WL}.container" <<EOF
[Unit]
Description=Propraetor Cache Intent stop probe

[Container]
Image=docker.io/valkey/valkey:9.1-alpine
ContainerName=${WL}
Network=service-network.network
Entrypoint=/bin/sleep
Exec=infinity

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF

"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"
ensure_cache_fulfillment
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"

host_ssh "test -f /home/platform/.config/platform/workloads/${WL}/cache/environment" \
  || fail "expected published Cache environment binding after fulfill"
host_ssh "test -f /home/platform/.config/containers/systemd/${WL}.container.d/50-platform-cache.conf" \
  || fail "expected Setup-owned Cache drop-in after fulfill"
host_ssh "test -f /host-volume/components/cache/persist/clients/${WL}/client.crt" \
  || fail "expected durable client cert after fulfill"
host_ssh "grep -E '^user ${WL} on resetpass' \
  /host-volume/components/cache/persist/conf/users.acl" \
  || fail "expected ACL user enabled for ${WL} after fulfill"
pass "Component Setup published binding for Intent run"

write_manifest stop
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"

still_published="$(host_ssh \
  "test -f /home/platform/.config/platform/workloads/${WL}/cache/environment && echo yes || echo no")"
[[ "${still_published}" == "yes" ]] \
  || fail "Workload Setup alone must not unpublish Cache binding on Intent stop"
pass "Workload Setup alone leaves Cache binding published on Intent stop"

ensure_cache_fulfillment

host_ssh "test ! -e /home/platform/.config/platform/workloads/${WL}/cache" \
  || fail "Component Setup must remove published Cache binding on Intent stop"
host_ssh "test ! -e /home/platform/.config/containers/systemd/${WL}.container.d/50-platform-cache.conf" \
  || fail "Component Setup must remove Cache drop-in on Intent stop"
host_ssh "grep -Eq '^user ${WL} off$' \
  /host-volume/components/cache/persist/conf/users.acl" \
  || fail "Component Setup must disable ACL user (${WL} off) on Intent stop"
if host_ssh "grep -E '^user ${WL} on ' \
  /host-volume/components/cache/persist/conf/users.acl"; then
  fail "ACL user must not remain enabled after Intent stop"
fi
pass "Component Setup unpublishes Cache binding and disables ACL user after Intent stop"

host_ssh "test -f /host-volume/components/cache/persist/clients/${WL}/client.crt" \
  || fail "durable client cert must remain until Orphan Reap"
pass "durable client material retained after Intent stop"

# Re-run with Intent run re-enables and publishes idempotently.
write_manifest run
"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"
ensure_cache_fulfillment

host_ssh "test -f /home/platform/.config/platform/workloads/${WL}/cache/environment" \
  || fail "expected Cache binding republished after Intent run"
host_ssh "test -f /home/platform/.config/containers/systemd/${WL}.container.d/50-platform-cache.conf" \
  || fail "expected Cache drop-in republished after Intent run"
host_ssh "grep -E '^user ${WL} on resetpass' \
  /host-volume/components/cache/persist/conf/users.acl" \
  || fail "expected ACL user re-enabled after Intent run"
pass "Intent run re-enables ACL user and republishes binding"
