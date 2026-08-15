#!/usr/bin/env bash
# Acceptance Test: environments/example web-api-with-db teaching Workload (#103 / ADR-0034).
# Materializes the committed example into the active Environment, Setups it, and asserts
# one-pod app+DB sidecar (localhost), Edge Route to the app only, and soft Host posture.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

WL=web-api-with-db
EXAMPLE_SRC="${REPO_ROOT}/environments/example/${WL}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

[[ -d "${EXAMPLE_SRC}" ]] || fail "missing teaching example at environments/example/${WL}"
acceptance_assert_artifact_tree "${EXAMPLE_SRC}" "example ${WL}"
python3 - "${EXAMPLE_SRC}/requires.json" <<'PY' || fail "example must Requires database:false (sidecar, not Database Component)"
import json, sys
req = json.load(open(sys.argv[1], encoding="utf-8"))
if req.get("database") is not False:
    raise SystemExit(f"expected Requires database false, got {req.get('database')!r}")
PY
[[ -f "${EXAMPLE_SRC}/systemd/${WL}.pod" ]] || fail "example missing soft-default pod ${WL}.pod"
[[ -f "${EXAMPLE_SRC}/systemd/${WL}-api.container" ]] \
  || fail "example missing app container ${WL}-api.container"
[[ -f "${EXAMPLE_SRC}/systemd/${WL}-db.container" ]] \
  || fail "example missing DB sidecar ${WL}-db.container"
[[ -f "${EXAMPLE_SRC}/routes/api.conf.example" ]] \
  || fail "example missing Route teaching fragment routes/api.conf.example"

grep -qE "^NetworkAlias=${WL}$" "${EXAMPLE_SRC}/systemd/${WL}.pod" \
  || fail "example pod must set NetworkAlias=${WL}"
grep -qE '^Network=service-network\.network$' "${EXAMPLE_SRC}/systemd/${WL}.pod" \
  || fail "example pod must join Service Network"
grep -qE '^PublishPort=' "${EXAMPLE_SRC}/systemd/${WL}.pod" \
  && fail "example pod must not PublishPort (soft: Workloads publish none)"

grep -qE "^Pod=${WL}\\.pod$" "${EXAMPLE_SRC}/systemd/${WL}-api.container" \
  || fail "api container must join ${WL}.pod"
grep -qE "^Pod=${WL}\\.pod$" "${EXAMPLE_SRC}/systemd/${WL}-db.container" \
  || fail "db container must join ${WL}.pod"
grep -qE "^Volume=\\.\\./persist:/var/lib/workload:rw$" \
  "${EXAMPLE_SRC}/systemd/${WL}-api.container" \
  || fail "api container must mount Persist via ../persist at /var/lib/workload"
grep -qE "^Volume=\\.\\./persist" \
  "${EXAMPLE_SRC}/systemd/${WL}-db.container" \
  || fail "db container must mount Persist via ../persist"
grep -qE '^Environment=PGDATA=/var/lib/workload/' \
  "${EXAMPLE_SRC}/systemd/${WL}-db.container" \
  || fail "db container should keep durable bytes under /var/lib/workload"
grep -qE '^PublishPort=' "${EXAMPLE_SRC}/systemd/${WL}-api.container" \
  && fail "api container must not PublishPort"
grep -qE '^PublishPort=' "${EXAMPLE_SRC}/systemd/${WL}-db.container" \
  && fail "db sidecar must not PublishPort (private on localhost)"

grep -qE "proxy_pass[[:space:]]+http://${WL}" \
  "${EXAMPLE_SRC}/routes/api.conf.example" \
  || fail "Route teaching fragment must proxy to Workload basename (app)"
grep -qE ":5432|${WL}-db" "${EXAMPLE_SRC}/routes/api.conf.example" \
  && fail "Route teaching fragment must expose the app only (not the DB)"

rm -rf "${FIX_DIR:?}/${WL:?}"
cp -R "${EXAMPLE_SRC}" "${FIX_DIR}/${WL}"
# Teaching fragment is Binding-attached, not copied to an FQDN filename.
ROUTE_FQDN="$(acceptance_route_fqdn)"
if [[ -n "${ROUTE_FQDN}" ]]; then
  acceptance_bind_route_fragment \
    "${FIX_DIR}/${WL}" "routes/api.conf.example" "${ROUTE_FQDN}"
fi

host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user stop ${WL}-pod.service ${WL}-api.service ${WL}-db.service 2>/dev/null || true
rm -rf /host-volume/workloads/${WL}
rm -f /home/platform/.config/containers/systemd/workload-${WL} \
  /home/platform/.config/containers/systemd/${WL}.pod \
  /home/platform/.config/containers/systemd/${WL}-api.container \
  /home/platform/.config/containers/systemd/${WL}-db.container
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
  "test -f /home/platform/.config/containers/systemd/workload-${WL}/${WL}-api.container" \
  || fail "Setup should install authored api container"
host_ssh \
  "test -f /home/platform/.config/containers/systemd/workload-${WL}/${WL}-db.container" \
  || fail "Setup should install authored db container"
pass "example web-api-with-db Setups cleanly (SoT + Host units)"

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
wait_active "${WL}-api.service" \
  || fail "Intent run should start Always-on ${WL}-api.service"
wait_active "${WL}-db.service" \
  || fail "Intent run should start Always-on ${WL}-db.service"
pass "Always-on pod, api, and db containers are active"

# Intra-pod: app container reaches private DB on localhost (shared net ns).
# nginx:1.31.3-alpine has wget (not necessarily nc); open Postgres port accepts TCP then resets —
# "can't connect" / "Connection refused" means the sidecar is not on localhost.
db_local_ok="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
ok=no
for _ in \$(seq 1 90); do
  runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
    bash -c 'cd "\$HOME" && podman exec ${WL}-db pg_isready -h 127.0.0.1 -U app' \
    >/dev/null 2>&1 || { sleep 1; continue; }
  err=\$(runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
    bash -c 'cd "\$HOME" && podman exec ${WL}-api wget -T 2 -O /dev/null 127.0.0.1:5432' \
    2>&1 || true)
  if ! printf '%s\n' "\${err}" | grep -Eqi "can.?t connect|connection refused"; then
    ok=yes
    break
  fi
  sleep 1
done
printf '%s\n' "\${ok}"
REMOTE
)"
[[ "${db_local_ok}" == "yes" ]] \
  || fail "api container should reach private DB on localhost:5432 (intra-pod)"
pass "intra-pod DB reachable on localhost from api container"

# Refresh Edge routes before Service Network / HTTPS probes.
ensure_edge_route_fulfillment
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
    bash -c 'cd "\$HOME" && podman exec systemd-edge-nginx wget -qO- -T 3 http://web-api-with-db/' \
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
  || fail "Service Network should reach Workload by basename web-api-with-db from Edge"
pass "Service Network basename reachability (web-api-with-db from Edge)"

probe_token="webapi-owned-$$"
host_ssh env "PROBE_TOKEN=${probe_token}" "WL=${WL}" bash -s <<'REMOTE'
set -euo pipefail
UID_NUM=$(id -u platform)
HOME_DIR=$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/${UID_NUM}
cid=$(runuser -u platform -- env HOME="${HOME_DIR}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_NUM}/bus" \
  bash -c 'cd "$HOME" && podman ps -q --filter name='"${WL}"'-api' | head -n1)
[[ -n "${cid}" ]] || { echo "missing ${WL}-api container" >&2; exit 1; }
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
     /home/platform/.config/containers/systemd/workload-${WL}/${WL}-api.container \
     /home/platform/.config/containers/systemd/workload-${WL}/${WL}-db.container 2>/dev/null || true")"
[[ -z "${publish_lines}" ]] \
  || fail "installed web-api-with-db units must not PublishPort (got: ${publish_lines})"

for cname in "${WL}-api" "${WL}-db"; do
  ports_json="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c 'cd "\$HOME" && podman inspect --format "{{json .HostConfig.PortBindings}}" ${cname}' 2>/dev/null || echo null
REMOTE
)"
  [[ "${ports_json}" == "{}" || "${ports_json}" == "null" || "${ports_json}" == "map[]" ]] \
    || fail "${cname} must not publish Host ports (PortBindings=${ports_json})"
done
pass "Workload publishes no Host ports (app and DB)"

if [[ -z "${ROUTE_FQDN}" ]]; then
  echo "SOFT-SKIP: empty Domain want-list — Route install / HTTPS attach assertions"
else
  installed="$(host_ssh \
    "cat /host-volume/components/edge/persist/routes/${WL}--${ROUTE_FQDN}.conf")"
  printf '%s\n' "${installed}" | grep -qE "proxy_pass[[:space:]]+http://${WL}" \
    || fail "installed Route must proxy to app basename only"
  printf '%s\n' "${installed}" | grep -qE ":5432|${WL}-db" \
    && fail "installed Route must not expose the DB"
  pass "Edge Route fragment installed for app only (${ROUTE_FQDN})"

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
    || fail "Domain-front HTTPS must serve app via Route (code='${code}' body='${body}')"
  pass "Domain-front HTTPS serves app Route (not DB)"
fi

cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{ "intent": "stop", "source": "internal" }
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${PLATFORM_ENV:-test}"
