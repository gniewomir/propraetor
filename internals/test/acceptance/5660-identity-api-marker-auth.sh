#!/usr/bin/env bash
# Acceptance Test: API enforces ${workload-slug}:api marker in token scope (#255).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
# shellcheck source=../../lib/identity/identity-config.sh
source "${REPO_ROOT}/internals/lib/identity/identity-config.sh"
# shellcheck source=../../lib/identity/identity-resource.sh
source "${REPO_ROOT}/internals/lib/identity/identity-resource.sh"
identity_config_issuer_fqdn_for "${ENV_SLUG}" >/dev/null \
  || fail "committed identity.json must validate for Environment ${ENV_SLUG}"
RESOURCE="$(identity_resource_aud_for_slug "${ENV_SLUG}")" \
  || fail "resource aud mapping failed"
ROUTE_FQDN="$(acceptance_route_fqdn)" \
  || fail "Domain want-list must provide a route FQDN for API auth probe"

FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=idapiauth
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

host_ssh \
  "rm -rf /host-volume/workloads/${WL} \
          /home/platform/.config/platform/workloads/${WL}" \
  || true

mkdir -p "${FIX_DIR}/${WL}/systemd" "${FIX_DIR}/${WL}/routes"
cat >"${FIX_DIR}/${WL}/manifest.json" <<EOF
{
  "intent": "run",
  "source": "internal",
  "description": "Identity API marker authorization probe"
}
EOF
acceptance_write_identity_api_auth_probe "${FIX_DIR}/${WL}" "${WL}"
cat >"${FIX_DIR}/${WL}/binding.json" <<EOF
{
  "domains": {
    "${ROUTE_FQDN}": ["routes/api.conf.example"]
  },
  "environment": {}
}
EOF
cat >"${FIX_DIR}/${WL}/routes/api.conf.example" <<EOF
location / {
    proxy_pass http://${WL}:8080;
}
EOF
cat >"${FIX_DIR}/${WL}/systemd/${WL}.pod" <<EOF
[Unit]
Description=Identity API auth probe pod

[Pod]
Network=service-network.network
NetworkAlias=${WL}

[Install]
WantedBy=default.target
EOF
cat >"${FIX_DIR}/${WL}/systemd/${WL}-api.container" <<EOF
[Unit]
Description=Identity API auth probe server

[Container]
Image=docker.io/library/python:3.12-alpine
ContainerName=${WL}-api
Pod=${WL}.pod
Volume=../app:/app:ro
Environment=LISTEN_HOST=0.0.0.0
Environment=LISTEN_PORT=8080
Exec=sh -c "pip install -q -r /app/requirements.txt && exec python /app/server.py"

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF

"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"
ensure_identity_fulfillment
ensure_edge_route_fulfillment

binding_env="/home/platform/.config/platform/workloads/${WL}/identity/resource-server.env"
host_ssh "test -f '${binding_env}'" \
  || fail "expected published Identity resource-server binding"
host_ssh "grep -Fx 'IDENTITY_MARKER_KEY=${WL}:api' '${binding_env}'" \
  || fail "published binding must include mandatory API marker permission key"
pass "Identity API claimant received resource-server binding with marker key"

host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user restart ${WL}-pod.service ${WL}-api.service
REMOTE

wait_active() {
  local unit="$1"
  local state=""
  local _
  for _ in $(seq 1 120); do
    state="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user show -p ActiveState --value ${unit} 2>/dev/null || echo ""
REMOTE
)"
    [[ "${state}" == "active" ]] && return 0
    sleep 2
  done
  return 1
}

wait_active "${WL}-pod.service" \
  || fail "Identity API auth probe pod must become active"
wait_active "${WL}-api.service" \
  || fail "Identity API auth probe server must become active"

health_ok="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
ok=no
for _ in \$(seq 1 60); do
  if runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
    bash -c 'cd "\$HOME" && podman exec ${WL}-api wget -qO- -T 3 http://127.0.0.1:8080/health' \
    >/dev/null 2>&1; then
    ok=yes
    break
  fi
  sleep 2
done
printf '%s\n' "\${ok}"
REMOTE
)"
[[ "${health_ok}" == "yes" ]] \
  || fail "example API health endpoint must respond before auth probes"
pass "example API server is running"

acceptance_wait_user_unit_active edge-nginx.service 60 \
  || fail "Edge nginx must be active before HTTPS API probes"

api_key_line="$(host_ssh "grep -E '^STATIC_API_KEY=' /host-volume/components/identity/persist/admin/environment | head -n1")"
[[ -n "${api_key_line}" ]] || fail "Identity admin STATIC_API_KEY missing on Host"
api_key="${api_key_line#STATIC_API_KEY=}"

extract_access_token() {
  python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])"
}

token_with_marker="$(
  acceptance_identity_mint_token "${WL}:api" "${RESOURCE}" "${WL}:api" "${api_key}" \
    | extract_access_token
)"
[[ -n "${token_with_marker}" ]] || fail "token mint with marker scope failed"

token_without_marker="$(
  acceptance_identity_mint_token "${WL}:read" "${RESOURCE}" "${WL}:read" "${api_key}" \
    | extract_access_token
)"
[[ -n "${token_without_marker}" ]] || fail "token mint without marker scope failed"

code_no_auth=""
for _ in $(seq 1 30); do
  code_no_auth="$(curl -skS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 \
    --resolve "${ROUTE_FQDN}:443:${IP}" "https://${ROUTE_FQDN}/" 2>/dev/null || true)"
  [[ "${code_no_auth}" == "401" ]] && break
  sleep 1
done
[[ "${code_no_auth}" == "401" ]] \
  || fail "example API must reject requests without Bearer token (code='${code_no_auth}')"
pass "example API rejects unauthenticated requests"

code_missing_marker=""
for _ in $(seq 1 30); do
  code_missing_marker="$(curl -skS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 \
    --resolve "${ROUTE_FQDN}:443:${IP}" \
    -H "Authorization: Bearer ${token_without_marker}" \
    "https://${ROUTE_FQDN}/" 2>/dev/null || true)"
  [[ "${code_missing_marker}" == "401" ]] && break
  sleep 1
done
[[ "${code_missing_marker}" == "401" ]] \
  || fail "example API must reject token missing ${WL}:api marker (code='${code_missing_marker}')"
pass "example API rejects Bearer token missing mandatory marker permission in scope"

body_with_marker=""
code_with_marker=""
for _ in $(seq 1 30); do
  body_with_marker="$(curl -skS --connect-timeout 10 --max-time 15 \
    --resolve "${ROUTE_FQDN}:443:${IP}" \
    -H "Authorization: Bearer ${token_with_marker}" \
    "https://${ROUTE_FQDN}/" 2>/dev/null || true)"
  code_with_marker="$(curl -skS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 \
    --resolve "${ROUTE_FQDN}:443:${IP}" \
    -H "Authorization: Bearer ${token_with_marker}" \
    "https://${ROUTE_FQDN}/" 2>/dev/null || true)"
  [[ "${code_with_marker}" == "200" ]] && break
  sleep 1
done
[[ "${code_with_marker}" == "200" ]] \
  || fail "example API must accept token with ${WL}:api marker (code='${code_with_marker}' body='${body_with_marker}')"
printf '%s\n' "${body_with_marker}" | grep -qx authorized \
  || fail "example API success body must be 'authorized'"
pass "example API accepts Bearer token containing mandatory marker permission in scope"
