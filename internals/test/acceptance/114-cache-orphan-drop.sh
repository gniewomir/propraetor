#!/usr/bin/env bash
# Acceptance Test: Orphan Reap → post-workloads drops Cache fulfillment (ADR-0055 / #225).
# Orphan Reap removes Host SoT; Cache drop runs on the next Component Setup post-workloads.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=cacheorphan
KEEP=cachekeep
acceptance_wl_track "${WL}" "${KEEP}"
trap 'acceptance_wl_cleanup' EXIT

host_ssh bash -s <<REMOTE
set -euo pipefail
for n in ${WL} ${KEEP}; do
  rm -rf "/host-volume/workloads/\${n}" \
         "/home/platform/.config/platform/workloads/\${n}"
  rm -f "/home/platform/.config/containers/systemd/\${n}"*.container
  rm -rf "/home/platform/.config/containers/systemd/\${n}"*.container.d
done
REMOTE

stage_wl() {
  local name="$1"
  mkdir -p "${FIX_DIR}/${name}/systemd"
  cat >"${FIX_DIR}/${name}/manifest.json" <<EOF
{
  "intent": "run",
  "source": "internal",
  "description": "Cache Orphan Reap drop probe"
}
EOF
  cat >"${FIX_DIR}/${name}/systemd/${name}.container" <<EOF
[Unit]
Description=Propraetor Cache Orphan Reap probe ${name}

[Container]
Image=docker.io/valkey/valkey:9.1-alpine
ContainerName=${name}
Network=service-network.network
Entrypoint=/bin/sleep
Exec=infinity

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF
}

stage_wl "${WL}"
acceptance_write_cache_claim "${FIX_DIR}/${WL}"
stage_wl "${KEEP}"
acceptance_write_artifact_stubs "${FIX_DIR}/${KEEP}"

"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"
ensure_cache_fulfillment
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"
"${REPO_ROOT}/internals/ensure-workload.sh" "${KEEP}" --env "${ENV_SLUG}"

host_ssh "test -f /host-volume/components/cache/persist/clients/${WL}/client.crt" \
  || fail "expected durable client cert for orphan candidate after fulfill"
host_ssh "grep -E '^user ${WL} on resetpass' \
  /host-volume/components/cache/persist/conf/users.acl" \
  || fail "expected ACL user enabled for ${WL} after fulfill"
pass "Component Setup fulfilled Cache for soon-to-be orphan"

# Seed a key under the orphan prefix via admin (proves best-effort prefix wipe).
seed_ok="$(host_ssh env "WL=${WL}" bash -s <<'REMOTE'
set -euo pipefail
UID_NUM=$(id -u platform)
HOME_DIR=$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/${UID_NUM}
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${UID_NUM}/bus
admin_user=$(grep -E '^CACHE_ADMIN_USER=' \
  /host-volume/components/cache/persist/admin/environment | head -n1 | cut -d= -f2-)
admin_pass=$(grep -E '^CACHE_ADMIN_PASSWORD=' \
  /host-volume/components/cache/persist/admin/environment | head -n1 | cut -d= -f2-)
[[ -n "${admin_user}" && -n "${admin_pass}" ]] || { echo missing-admin; exit 0; }
out=$(runuser -u platform -- env HOME="${HOME_DIR}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
  CACHE_ACL_USER="${admin_user}" CACHE_ACL_PASS="${admin_pass}" WL="${WL}" \
  bash -c 'cd "$HOME" && podman exec \
    -e CACHE_ACL_USER -e CACHE_ACL_PASS -e WL \
    cache-valkey \
    valkey-cli --tls \
      --cacert /etc/cache-certs/ca.crt \
      --cert /etc/cache-certs/admin.crt \
      --key /etc/cache-certs/admin.key \
      --user "$CACHE_ACL_USER" \
      -a "$CACHE_ACL_PASS" \
      SET "${WL}:orphan-probe" seeded' 2>/dev/null || true)
if printf '%s\n' "${out}" | grep -Eq '^OK$'; then
  echo yes
else
  echo "no out=${out}"
fi
REMOTE
)"
[[ "${seed_ok}" == "yes" ]] \
  || fail "admin must seed ${WL}:orphan-probe before Orphan Reap (got '${seed_ok}')"
pass "seeded prefix key for orphan candidate"

# Drop from Environment → Host leftover becomes an orphan (Mirror leaves it alone).
rm -rf "${FIX_DIR:?}/${WL}"
"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"
host_ssh "test -f /host-volume/workloads/${WL}/manifest.json" \
  || fail "Mirror must leave orphan SoT alone before Orphan Reap"

"${REPO_ROOT}/internals/purge-orphans.sh" --env "${ENV_SLUG}"

host_ssh "test ! -e /host-volume/workloads/${WL}" \
  || fail "Orphan Reap must remove orphan SoT"
host_ssh "test -f /host-volume/components/cache/persist/clients/${WL}/client.crt" \
  || fail "Orphan Reap alone must not drop Cache client material"
host_ssh "grep -E '^user ${WL} ' \
  /host-volume/components/cache/persist/conf/users.acl" \
  || fail "Orphan Reap alone must not rewrite Cache ACL file"
pass "Orphan Reap alone leaves ACL user line and client material"

ensure_cache_post_workloads

host_ssh "test ! -e /host-volume/components/cache/persist/clients/${WL}" \
  || fail "post-workloads must remove durable client material after Orphan Reap"
host_ssh "test ! -e /home/platform/.config/platform/workloads/${WL}/cache" \
  || fail "post-workloads must clear published Cache binding after Orphan Reap"
host_ssh "test ! -e /home/platform/.config/containers/systemd/${WL}.container.d/50-platform-cache.conf" \
  || fail "post-workloads must clear Cache drop-in after Orphan Reap"
host_ssh "test -f /host-volume/workloads/${KEEP}/manifest.json" \
  || fail "post-workloads must leave Environment Workloads alone"
if host_ssh "grep -E '^user ${WL} ' \
  /host-volume/components/cache/persist/conf/users.acl"; then
  fail "post-workloads must remove ACL user line for ${WL}"
fi
pass "post-workloads clears clients, binding, drop-in, and ACL file line"

gone_ok="$(host_ssh env "WL=${WL}" bash -s <<'REMOTE'
set -euo pipefail
UID_NUM=$(id -u platform)
HOME_DIR=$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/${UID_NUM}
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${UID_NUM}/bus
admin_user=$(grep -E '^CACHE_ADMIN_USER=' \
  /host-volume/components/cache/persist/admin/environment | head -n1 | cut -d= -f2-)
admin_pass=$(grep -E '^CACHE_ADMIN_PASSWORD=' \
  /host-volume/components/cache/persist/admin/environment | head -n1 | cut -d= -f2-)
[[ -n "${admin_user}" && -n "${admin_pass}" ]] || { echo missing-admin; exit 0; }
users=$(runuser -u platform -- env HOME="${HOME_DIR}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
  CACHE_ACL_USER="${admin_user}" CACHE_ACL_PASS="${admin_pass}" \
  bash -c 'cd "$HOME" && podman exec \
    -e CACHE_ACL_USER -e CACHE_ACL_PASS \
    cache-valkey \
    valkey-cli --tls \
      --cacert /etc/cache-certs/ca.crt \
      --cert /etc/cache-certs/admin.crt \
      --key /etc/cache-certs/admin.key \
      --user "$CACHE_ACL_USER" \
      -a "$CACHE_ACL_PASS" \
      ACL LIST' 2>/dev/null || true)
key=$(runuser -u platform -- env HOME="${HOME_DIR}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
  CACHE_ACL_USER="${admin_user}" CACHE_ACL_PASS="${admin_pass}" WL="${WL}" \
  bash -c 'cd "$HOME" && podman exec \
    -e CACHE_ACL_USER -e CACHE_ACL_PASS -e WL \
    cache-valkey \
    valkey-cli --tls \
      --cacert /etc/cache-certs/ca.crt \
      --cert /etc/cache-certs/admin.crt \
      --key /etc/cache-certs/admin.key \
      --user "$CACHE_ACL_USER" \
      -a "$CACHE_ACL_PASS" \
      GET "${WL}:orphan-probe"' 2>/dev/null || true)
if printf '%s\n' "${users}" | grep -Eq "^user ${WL} "; then
  echo "no user-still-listed"
elif printf '%s\n' "${key}" | grep -Eqv '^\(nil\)$|^$'; then
  echo "no key=${key}"
else
  echo yes
fi
REMOTE
)"
[[ "${gone_ok}" == "yes" ]] \
  || fail "post-workloads must DELUSER and wipe prefix keys after Orphan Reap (got '${gone_ok}')"
pass "post-workloads drops Cache fulfillment after Orphan Reap"
