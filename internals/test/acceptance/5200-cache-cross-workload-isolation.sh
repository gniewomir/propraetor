#!/usr/bin/env bash
# Acceptance Test: cross-Workload Cache prefix isolation (ADR-0055 / #223).
# Two Intent-run Cache claimants — A cannot read/write B's keys; SCAN/KEYS/
# FLUSHALL/SELECT denied for Workload users.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WLA=cacheisoa
WLB=cacheisob
acceptance_wl_track "${WLA}" "${WLB}"
trap 'acceptance_wl_cleanup' EXIT

host_ssh \
  "rm -rf /host-volume/workloads/${WLA} \
          /host-volume/workloads/${WLB} \
          /home/platform/.config/platform/workloads/${WLA} \
          /home/platform/.config/platform/workloads/${WLB}; \
   rm -f /home/platform/.config/containers/systemd/${WLA}*.container \
         /home/platform/.config/containers/systemd/${WLB}*.container; \
   rm -rf /home/platform/.config/containers/systemd/${WLA}*.container.d \
          /home/platform/.config/containers/systemd/${WLB}*.container.d" \
  || true

write_probe_workload() {
  local name="$1"
  mkdir -p "${FIX_DIR}/${name}/systemd"
  cat >"${FIX_DIR}/${name}/manifest.json" <<EOF
{
  "intent": "run",
  "source": "internal",
  "description": "cross-Workload Cache isolation probe (${name})"
}
EOF
  acceptance_write_cache_claim "${FIX_DIR}/${name}"
  cat >"${FIX_DIR}/${name}/systemd/${name}.container" <<EOF
[Unit]
Description=Propraetor Cache isolation probe ${name}

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

write_probe_workload "${WLA}"
write_probe_workload "${WLB}"

# Mirror SoT first so pre-workloads gather sees both Declarations.
"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"
ensure_cache_fulfillment

host_ssh "grep -E '^user ${WLA} on resetpass ~${WLA}:\\*' \
  /host-volume/components/cache/persist/conf/users.acl" \
  || fail "expected ACL user for ${WLA}"
host_ssh "grep -E '^user ${WLB} on resetpass ~${WLB}:\\*' \
  /host-volume/components/cache/persist/conf/users.acl" \
  || fail "expected ACL user for ${WLB}"
host_ssh "grep -F '+@keyspace' \
  /host-volume/components/cache/persist/conf/users.acl" \
  && fail "Workload ACL must not grant +@keyspace"
pass "Component Setup published ACL users for both claimants (no +@keyspace)"

"${REPO_ROOT}/internals/ensure-workload.sh" "${WLA}" --env "${ENV_SLUG}"
"${REPO_ROOT}/internals/ensure-workload.sh" "${WLB}" --env "${ENV_SLUG}"

# Wait until Workload can SET/GET under its own CACHE_KEY_PREFIX (passwordless mTLS).
wait_own_prefix() {
  local wl="$1"
  host_ssh env "WL=${wl}" bash -s <<'REMOTE'
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
}

a_ok="$(wait_own_prefix "${WLA}")"
[[ "${a_ok}" == "yes" ]] \
  || fail "Workload ${WLA} should SET/GET under its own prefix"
pass "Workload ${WLA} can use its own prefix"

b_ok="$(wait_own_prefix "${WLB}")"
[[ "${b_ok}" == "yes" ]] \
  || fail "Workload ${WLB} should SET/GET under its own prefix"
pass "Workload ${WLB} can use its own prefix"

# A SET/GET on B's prefix must return NOPERM (key pattern isolation).
# FOREIGN_PREFIX is injected so the container sh only expands CACHE_* + FOREIGN_*.
cross_out="$(host_ssh env "WLA=${WLA}" "FOREIGN_PREFIX=${WLB}:" bash -s <<'REMOTE'
set -euo pipefail
UID_NUM=$(id -u platform)
HOME_DIR=$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/${UID_NUM}
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${UID_NUM}/bus
runuser -u platform -- env HOME="${HOME_DIR}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
  WLA="${WLA}" FOREIGN_PREFIX="${FOREIGN_PREFIX}" \
  bash -c 'cd "$HOME" && podman exec -e FOREIGN_PREFIX="$FOREIGN_PREFIX" "$WLA" sh -c '"'"'valkey-cli --tls -h "$CACHE_HOST" -p "$CACHE_PORT" --cacert "$CACHE_CA_CERT" --cert "$CACHE_CLIENT_CERT" --key "$CACHE_CLIENT_KEY" SET "${FOREIGN_PREFIX}foreign" deny-me; valkey-cli --tls -h "$CACHE_HOST" -p "$CACHE_PORT" --cacert "$CACHE_CA_CERT" --cert "$CACHE_CLIENT_CERT" --key "$CACHE_CLIENT_KEY" GET "${FOREIGN_PREFIX}foreign"'"'"'' \
  2>&1 || true
REMOTE
)"
printf '%s\n' "${cross_out}" | grep -Fq 'NOPERM' \
  || fail "Workload ${WLA} SET/GET on ${WLB}:* must return NOPERM (got: ${cross_out})"
printf '%s\n' "${cross_out}" | grep -Eqi '^(OK|deny-me)$' \
  && fail "Workload ${WLA} must not succeed on ${WLB}:* keys (got: ${cross_out})"
pass "Workload ${WLA} cannot SET/GET under Workload ${WLB}'s prefix (NOPERM)"

# Command whitelist denies keyspace walkers / dangerous commands.
deny_cmds_out="$(host_ssh env "WL=${WLA}" bash -s <<'REMOTE'
set -euo pipefail
UID_NUM=$(id -u platform)
HOME_DIR=$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/${UID_NUM}
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${UID_NUM}/bus
runuser -u platform -- env HOME="${HOME_DIR}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" WL="${WL}" \
  bash -c 'cd "$HOME" && podman exec "$WL" sh -c '"'"'
cli() { valkey-cli --tls -h "$CACHE_HOST" -p "$CACHE_PORT" --cacert "$CACHE_CA_CERT" --cert "$CACHE_CLIENT_CERT" --key "$CACHE_CLIENT_KEY" "$@"; }
cli SCAN 0
cli KEYS "*"
cli FLUSHALL
cli SELECT 1
'"'"'' \
  2>&1 || true
REMOTE
)"
noperm_count="$(printf '%s\n' "${deny_cmds_out}" | grep -c 'NOPERM' || true)"
[[ "${noperm_count}" -ge 4 ]] \
  || fail "expected NOPERM for SCAN/KEYS/FLUSHALL/SELECT (got ${noperm_count}: ${deny_cmds_out})"
# Error text names the denied command (defense that we actually ran each).
for cmd in scan keys flushall select; do
  printf '%s\n' "${deny_cmds_out}" | grep -Fi "'${cmd}'" >/dev/null \
    || fail "expected NOPERM naming '${cmd}' (got: ${deny_cmds_out})"
done
pass "SCAN, KEYS, FLUSHALL, SELECT denied for Workload users (NOPERM)"
