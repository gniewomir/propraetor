#!/usr/bin/env bash
# Acceptance Test: one Workload passwordless mTLS Cache binding (ADR-0055 / #222).
# Intent-run + Requires cache:true → ACL user/client cert + published binding;
# live SET/GET under CACHE_KEY_PREFIX without AUTH password.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=cachemtls
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

host_ssh \
  "rm -rf /host-volume/workloads/${WL} \
          /home/platform/.config/platform/workloads/${WL}; \
   rm -f /home/platform/.config/containers/systemd/${WL}*.container; \
   rm -rf /home/platform/.config/containers/systemd/${WL}*.container.d" \
  || true

mkdir -p "${FIX_DIR}/${WL}/systemd"
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "description": "passwordless mTLS Cache probe"
}
EOF
acceptance_write_cache_claim "${FIX_DIR}/${WL}"
cat >"${FIX_DIR}/${WL}/systemd/${WL}.container" <<EOF
[Unit]
Description=Propraetor Cache mTLS probe

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

# Mirror SoT first so pre-workloads gather sees the Declaration (ADR-0041 / ADR-0055).
"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"
ensure_cache_fulfillment

# Published binding + client material from Component Setup (Requires-driven).
host_ssh "test -f /home/platform/.config/platform/workloads/${WL}/cache/environment" \
  || fail "expected published Cache environment binding"
host_ssh "test -f /home/platform/.config/platform/workloads/${WL}/cache/client.crt" \
  || fail "expected published client.crt"
host_ssh "test -f /host-volume/components/cache/persist/clients/${WL}/client.crt" \
  || fail "expected Host Volume client cert"
host_ssh "grep -Fx 'CACHE_KEY_PREFIX=${WL}:' \
  /home/platform/.config/platform/workloads/${WL}/cache/environment" \
  || fail "expected CACHE_KEY_PREFIX=${WL}:"
host_ssh "grep -E '^(CACHE_PASSWORD|CACHE_AUTH|REDIS_PASSWORD)=' \
  /home/platform/.config/platform/workloads/${WL}/cache/environment" \
  && fail "published Cache env must not include a password"
host_ssh "grep -E '^user ${WL} on resetpass' \
  /host-volume/components/cache/persist/conf/users.acl" \
  || fail "expected ACL user for ${WL}"
pass "Component Setup created client material and published passwordless binding"

# Workload Setup picks up Setup-owned drop-in on start.
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"

# Wait for Always-on unit, then passwordless mTLS SET/GET under prefix (no AUTH password).
# Inner sh -c is single-quoted so CACHE_* expand inside the container.
connect_ok="$(host_ssh env "WL=${WL}" bash -s <<'REMOTE'
set -euo pipefail
UID_NUM=$(id -u platform)
HOME_DIR=$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/${UID_NUM}
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${UID_NUM}/bus
ok=no
for _ in $(seq 1 60); do
  if runuser -u platform -- env HOME="${HOME_DIR}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
    DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" WL="${WL}" \
    bash -c 'cd "$HOME" && systemctl --user --quiet is-active "$WL".service' \
    >/dev/null 2>&1; then
    out=$(runuser -u platform -- env HOME="${HOME_DIR}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
      DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" WL="${WL}" \
      bash -c 'cd "$HOME" && podman exec "$WL" sh -c '"'"'valkey-cli --tls -h "$CACHE_HOST" -p "$CACHE_PORT" --cacert "$CACHE_CA_CERT" --cert "$CACHE_CLIENT_CERT" --key "$CACHE_CLIENT_KEY" SET "${CACHE_KEY_PREFIX}probe" ok && valkey-cli --tls -h "$CACHE_HOST" -p "$CACHE_PORT" --cacert "$CACHE_CA_CERT" --cert "$CACHE_CLIENT_CERT" --key "$CACHE_CLIENT_KEY" GET "${CACHE_KEY_PREFIX}probe"'"'"'' \
      2>/dev/null || true)
    if printf '%s\n' "${out}" | grep -Eq '^ok$'; then
      ok=yes
      break
    fi
  fi
  sleep 1
done
printf '%s\n' "${ok}"
REMOTE
)"
[[ "${connect_ok}" == "yes" ]] \
  || fail "Workload ${WL} should SET/GET under prefix over passwordless mTLS"
pass "Workload connects to Cache with client cert (passwordless mTLS SET/GET)"
