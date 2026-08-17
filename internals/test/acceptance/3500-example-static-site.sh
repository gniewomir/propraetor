#!/usr/bin/env bash
# Acceptance Test: environments/example static-site teaching Workload (#105 / ADR-0034).
# Materializes the committed example into the active Environment, Setups it, and asserts
# Edge Route attachment plus soft Host posture (Service Network basename, owned Host Volume,
# no Workload Host ports).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

WL=static-site
EXAMPLE_SRC="${REPO_ROOT}/environments/example/${WL}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

[[ -d "${EXAMPLE_SRC}" ]] || fail "missing teaching example at environments/example/${WL}"
acceptance_assert_artifact_tree "${EXAMPLE_SRC}" "example ${WL}"
[[ -f "${EXAMPLE_SRC}/systemd/${WL}.pod" ]] || fail "example missing soft-default pod ${WL}.pod"
[[ -f "${EXAMPLE_SRC}/systemd/${WL}-web.container" ]] \
  || fail "example missing member container ${WL}-web.container"
[[ -f "${EXAMPLE_SRC}/routes/site.conf.example" ]] \
  || fail "example missing Route teaching fragment routes/site.conf.example"

grep -qE "^NetworkAlias=${WL}$" "${EXAMPLE_SRC}/systemd/${WL}.pod" \
  || fail "example pod must set NetworkAlias=${WL}"
grep -qE '^Network=service-network\.network$' "${EXAMPLE_SRC}/systemd/${WL}.pod" \
  || fail "example pod must join Service Network"
grep -qE '^PublishPort=' "${EXAMPLE_SRC}/systemd/${WL}.pod" \
  && fail "example pod must not PublishPort (soft: Workloads publish none)"

grep -qE "^Pod=${WL}\\.pod$" "${EXAMPLE_SRC}/systemd/${WL}-web.container" \
  || fail "web container must join ${WL}.pod"
grep -qE "^Volume=\\.\\./persist:/var/lib/workload:rw$" \
  "${EXAMPLE_SRC}/systemd/${WL}-web.container" \
  || fail "web container must mount Persist via ../persist at /var/lib/workload"
grep -qE '^PublishPort=' "${EXAMPLE_SRC}/systemd/${WL}-web.container" \
  && fail "web container must not PublishPort"

grep -qE "proxy_pass[[:space:]]+http://${WL}" \
  "${EXAMPLE_SRC}/routes/site.conf.example" \
  || fail "Route teaching fragment must proxy to Workload basename"

rm -rf "${FIX_DIR:?}/${WL:?}"
cp -R "${EXAMPLE_SRC}" "${FIX_DIR}/${WL}"
# Teaching fragment is Binding-attached, not copied to an FQDN filename.
ROUTE_FQDN="$(acceptance_route_fqdn)"
if [[ -n "${ROUTE_FQDN}" ]]; then
  acceptance_bind_route_fragment \
    "${FIX_DIR}/${WL}" "routes/site.conf.example" "${ROUTE_FQDN}"
fi

host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user stop ${WL}-pod.service ${WL}-web.service 2>/dev/null || true
rm -rf /host-volume/workloads/${WL}
rm -f /home/platform/.config/containers/systemd/workload-${WL} \
  /home/platform/.config/containers/systemd/${WL}.pod \
  /home/platform/.config/containers/systemd/${WL}-web.container
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR systemctl --user daemon-reload
REMOTE

"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${PLATFORM_ENV:-test}"

host_ssh \
  "test -f /host-volume/workloads/${WL}/systemd/${WL}.pod" \
  || fail "Setup should store authored pod SoT"
host_ssh \
  "test -f /home/platform/.config/containers/systemd/workload-${WL}/${WL}.pod" \
  || fail "Setup should install authored pod unit via workload dir symlink"
host_ssh \
  "test -f /home/platform/.config/containers/systemd/workload-${WL}/${WL}-web.container" \
  || fail "Setup should install authored member container"
pass "example static-site Setups cleanly (SoT + Host units)"

wait_active() {
  local unit="$1"
  local state=""
  local _
  for _ in $(seq 1 90); do
    state="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user show -p ActiveState --value ${unit} 2>/dev/null || echo ""
REMOTE
)"
    [[ "${state}" == "active" ]] && return 0
    sleep 1
  done
  return 1
}

wait_active "${WL}-pod.service" \
  || fail "Intent run should start Always-on ${WL}-pod.service"
wait_active "${WL}-web.service" \
  || fail "Intent run should start Always-on ${WL}-web.service"
pass "Always-on pod and member container are active"

# Soft Host posture: Service Network basename, owned volume, no Workload Host ports.
reach_ok="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
ok=no
for _ in \$(seq 1 30); do
  if runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
    bash -c 'cd "\$HOME" && podman exec systemd-edge-nginx wget -qO- -T 3 http://static-site/' \
    >/dev/null 2>&1; then
    ok=yes
    break
  fi
  sleep 1
done
printf '%s\n' "\${ok}"
REMOTE
)"
[[ "${reach_ok}" == "yes" ]] \
  || fail "Service Network should reach Workload by basename static-site from Edge"
pass "Service Network basename reachability (static-site from Edge)"

probe_token="static-owned-$$"
host_ssh env "PROBE_TOKEN=${probe_token}" "WL=${WL}" bash -s <<'REMOTE'
set -euo pipefail
UID_NUM=$(id -u platform)
HOME_DIR=$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/${UID_NUM}
cid=$(runuser -u platform -- env HOME="${HOME_DIR}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_NUM}/bus" \
  bash -c 'cd "$HOME" && podman ps -q --filter name='"${WL}"'-web' | head -n1)
[[ -n "${cid}" ]] || { echo "missing ${WL}-web container" >&2; exit 1; }
runuser -u platform -- env HOME="${HOME_DIR}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_NUM}/bus" \
  PROBE_TOKEN="${PROBE_TOKEN}" \
  bash -c 'cd "$HOME" && printf %s "$PROBE_TOKEN" | podman exec -i '"${cid}"' sh -c "cat >/var/lib/workload/acceptance-owned"'
test -f "/host-volume/workloads/${WL}/persist/acceptance-owned"
grep -qx "${PROBE_TOKEN}" "/host-volume/workloads/${WL}/persist/acceptance-owned"
REMOTE
pass "nested Persist mounted RW at /var/lib/workload"

publish_lines="$(host_ssh \
  "grep -hE '^PublishPort=' /home/platform/.config/containers/systemd/workload-${WL}/${WL}.pod \
     /home/platform/.config/containers/systemd/workload-${WL}/${WL}-web.container 2>/dev/null || true")"
[[ -z "${publish_lines}" ]] \
  || fail "installed static-site units must not PublishPort (got: ${publish_lines})"
ports_json="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c 'cd "\$HOME" && podman inspect --format "{{json .HostConfig.PortBindings}}" ${WL}-web' 2>/dev/null || echo null
REMOTE
)"
[[ "${ports_json}" == "{}" || "${ports_json}" == "null" || "${ports_json}" == "map[]" ]] \
  || fail "static-site must not publish Host ports (PortBindings=${ports_json})"
pass "Workload publishes no Host ports"

if [[ -z "${ROUTE_FQDN}" ]]; then
  echo "SOFT-SKIP: empty Domain want-list — Route install / HTTPS attach assertions"
else
  ensure_edge_route_fulfillment
  installed="$(host_ssh \
    "cat /host-volume/components/edge/persist/routes/${WL}--${ROUTE_FQDN}.conf")"
  printf '%s\n' "${installed}" | grep -qE "proxy_pass[[:space:]]+http://${WL}" \
    || fail "installed Route must proxy to Workload basename"
  pass "Edge Route fragment installed (${ROUTE_FQDN})"

  host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM="\$(id -u platform)"
export XDG_RUNTIME_DIR="/run/user/\${UID_NUM}"
systemctl start "user@\${UID_NUM}.service"
runuser -u platform -- env XDG_RUNTIME_DIR="\$XDG_RUNTIME_DIR" systemctl --user reset-failed edge-nginx.service edge-pod.service 2>/dev/null || true
runuser -u platform -- env XDG_RUNTIME_DIR="\$XDG_RUNTIME_DIR" systemctl --user restart edge-pod.service
REMOTE
  acceptance_wait_user_unit_active edge-nginx.service 60 \
    || fail "Edge nginx must be active after Route gather"

  body=""
  code=""
  for _ in $(seq 1 30); do
    body="$(curl -skS --connect-timeout 10 --max-time 15 \
      --resolve "${ROUTE_FQDN}:443:${IP}" "https://${ROUTE_FQDN}/" 2>/dev/null || true)"
    code="$(curl -skS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 \
      --resolve "${ROUTE_FQDN}:443:${IP}" "https://${ROUTE_FQDN}/" 2>/dev/null || true)"
    [[ "${code}" == "200" ]] && break
    sleep 1
  done
  [[ "${code}" == "200" ]] \
    || fail "Domain-front HTTPS must serve static-site via Route (code='${code}' body='${body}')"
  pass "Domain-front HTTPS serves static-site Route"
fi

cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{ "intent": "stop", "source": "internal" }
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${PLATFORM_ENV:-test}"
