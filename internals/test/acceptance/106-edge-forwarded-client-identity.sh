#!/usr/bin/env bash
# Acceptance Test: Edge overwrites Forwarded client identity (ADR-0052).
# Spoofed inbound X-Forwarded-* / Forwarded must not reach the upstream; Edge sets
# values from the public TCP peer and scheme/host instead.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ROUTE_FQDN="$(acceptance_route_fqdn)"
if [[ -z "${ROUTE_FQDN}" ]]; then
  echo "SOFT-SKIP: empty Domain want-list — no FQDN for Forwarded client identity proof"
  exit 0
fi

WL=fwd-probe
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

SPOOF_IP=203.0.113.99
SPOOF_FOR="for=${SPOOF_IP}"
SPOOF_PROTO=http
SPOOF_HOST=spoof.example.invalid

rm -rf "${FIX_DIR:?}/${WL:?}"
mkdir -p "${FIX_DIR}/${WL}/systemd" "${FIX_DIR}/${WL}/routes"
acceptance_write_artifact_stubs "${FIX_DIR}/${WL}"

cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "description": "Ephemeral Acceptance probe: echo proxied request headers."
}
EOF

cat >"${FIX_DIR}/${WL}/systemd/${WL}.pod" <<EOF
[Pod]
Network=service-network.network
NetworkAlias=${WL}
EOF

# Echo headers Edge set on the proxied request (upstream nginx variables).
cat >"${FIX_DIR}/${WL}/echo.conf" <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    location / {
        default_type text/plain;
        return 200 "xff=$http_x_forwarded_for\nxri=$http_x_real_ip\nxfp=$http_x_forwarded_proto\nxfh=$http_x_forwarded_host\nfwd=$http_forwarded\nhost=$http_host\n";
    }
}
EOF

cat >"${FIX_DIR}/${WL}/systemd/${WL}-web.container" <<EOF
[Unit]
Description=Propraetor Acceptance Forwarded client identity probe

[Container]
Image=docker.io/library/nginx:1.31.3-alpine
ContainerName=${WL}-web
Pod=${WL}.pod
Volume=../echo.conf:/etc/nginx/conf.d/default.conf:ro

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF

cat >"${FIX_DIR}/${WL}/routes/probe.conf" <<EOF
location / {
    proxy_pass http://${WL};
}
EOF
acceptance_bind_route_fragment "${FIX_DIR}/${WL}" "routes/probe.conf" "${ROUTE_FQDN}"

"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${PLATFORM_ENV:-test}"
ensure_edge_route_fulfillment

acceptance_wait_user_unit_active "${WL}-pod.service" 90 \
  || fail "fwd-probe pod must be active"
acceptance_wait_user_unit_active "${WL}-web.service" 90 \
  || fail "fwd-probe web must be active"
acceptance_wait_user_unit_active edge-pod.service 60 \
  || fail "Edge pod must be active after Route fulfillment"
acceptance_wait_user_unit_active edge-nginx.service 60 \
  || fail "Edge nginx must be active after Route fulfillment"

body=""
code=""
for _ in $(seq 1 45); do
  body="$(curl -skS --connect-timeout 10 --max-time 15 \
    --resolve "${ROUTE_FQDN}:443:${IP}" \
    -H "X-Forwarded-For: ${SPOOF_IP}" \
    -H "X-Real-IP: ${SPOOF_IP}" \
    -H "X-Forwarded-Proto: ${SPOOF_PROTO}" \
    -H "X-Forwarded-Host: ${SPOOF_HOST}" \
    -H "Forwarded: ${SPOOF_FOR};proto=${SPOOF_PROTO};host=${SPOOF_HOST}" \
    "https://${ROUTE_FQDN}/" 2>/dev/null || true)"
  code="$(curl -skS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 \
    --resolve "${ROUTE_FQDN}:443:${IP}" \
    -H "X-Forwarded-For: ${SPOOF_IP}" \
    "https://${ROUTE_FQDN}/" 2>/dev/null || true)"
  [[ "${code}" == "200" && -n "${body}" ]] && break
  sleep 1
done
[[ "${code}" == "200" ]] \
  || fail "Domain-front HTTPS must reach fwd-probe (code='${code}' body='${body}')"

# Line-anchored: "xfp=http" must not match substring of "xfp=https".
printf '%s\n' "${body}" | grep -Eq "^xff=${SPOOF_IP}$" \
  && fail "X-Forwarded-For must not retain spoofed ${SPOOF_IP} (body=${body})"
printf '%s\n' "${body}" | grep -Eq "^xri=${SPOOF_IP}$" \
  && fail "X-Real-IP must not retain spoofed ${SPOOF_IP} (body=${body})"
printf '%s\n' "${body}" | grep -Eq "^xfp=${SPOOF_PROTO}$" \
  && fail "X-Forwarded-Proto must not retain spoofed ${SPOOF_PROTO} (body=${body})"
printf '%s\n' "${body}" | grep -Eq "^xfh=${SPOOF_HOST}$" \
  && fail "X-Forwarded-Host must not retain spoofed ${SPOOF_HOST} (body=${body})"
printf '%s\n' "${body}" | grep -Eq "^fwd=${SPOOF_FOR};" \
  && fail "Forwarded must not retain spoofed ${SPOOF_FOR} (body=${body})"
printf '%s\n' "${body}" | grep -Eq "^host=${SPOOF_HOST}$" \
  && fail "Host must not retain spoofed ${SPOOF_HOST} (body=${body})"

printf '%s\n' "${body}" | grep -Eq '^xff=[0-9a-fA-F.:]+$' \
  || fail "X-Forwarded-For must be overwritten to TCP peer (body=${body})"
printf '%s\n' "${body}" | grep -Eq '^xri=[0-9a-fA-F.:]+$' \
  || fail "X-Real-IP must be overwritten to TCP peer (body=${body})"
printf '%s\n' "${body}" | grep -Eq '^xfp=https$' \
  || fail "X-Forwarded-Proto must be https on Domain front (body=${body})"
printf '%s\n' "${body}" | grep -Eq "^xfh=${ROUTE_FQDN}$" \
  || fail "X-Forwarded-Host must be ${ROUTE_FQDN} (body=${body})"
printf '%s\n' "${body}" | grep -Eq "^host=${ROUTE_FQDN}$" \
  || fail "Host must be ${ROUTE_FQDN} (body=${body})"
printf '%s\n' "${body}" | grep -Eq '^fwd=for=' \
  || fail "Forwarded must be present with for= (body=${body})"
printf '%s\n' "${body}" | grep -Eq "proto=https" \
  || fail "Forwarded must include proto=https (body=${body})"
printf '%s\n' "${body}" | grep -Eq "host=${ROUTE_FQDN}" \
  || fail "Forwarded must include host=${ROUTE_FQDN} (body=${body})"

pass "Edge overwrites Forwarded client identity; spoofed inbound headers discarded"
