#!/usr/bin/env bash
# Acceptance Test: Workload Route fragment served via Domain-front HTTPS (ADR-0028)
# Soft-skips when Domain want-list is empty. Domain-front /healthcheck stays on 83.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

HOST="$(acceptance_route_fqdn)"
if [[ -z "${HOST}" ]]; then
  echo "SOFT-SKIP: empty Domain want-list — no FQDN for Route fragment probe"
  exit 0
fi

WL="tlsprobe"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

mkdir -p "${FIX_DIR}/${WL}/routes"
acceptance_write_artifact_stubs "${FIX_DIR}/${WL}"
cat >"${FIX_DIR}/${WL}/manifest.json" <<EOF
{
  "intent": "run",
  "source": "internal"
}
EOF
cat >"${FIX_DIR}/${WL}/routes/probe.conf" <<EOF
location = /tlsprobe {
    default_type text/plain;
    return 200 'tlsprobe-ok';
}
EOF
acceptance_bind_route_fragment "${FIX_DIR}/${WL}" "routes/probe.conf" "${HOST}"

host_ssh \
  "rm -rf /host-volume/workloads/${WL}"

"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${PLATFORM_ENV:-test}"
ensure_edge_route_fulfillment

installed="$(host_ssh \
  "cat /host-volume/components/edge/persist/routes/${WL}--${HOST}.conf")"
echo "${installed}" | grep -Fq 'location = /tlsprobe' \
  || fail "operator Route fragment must be installed as authored"
pass "Operator Route fragment installed for Domain-front include (${HOST})"

# Reload Edge so the Domain front picks up the new fragment.
host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM="\$(id -u platform)"
export XDG_RUNTIME_DIR="/run/user/\${UID_NUM}"
systemctl start "user@\${UID_NUM}.service"
runuser -u platform -- env XDG_RUNTIME_DIR="\$XDG_RUNTIME_DIR" systemctl --user restart edge-pod.service
REMOTE

body=""
code=""
for _ in $(seq 1 30); do
  body="$(curl -skS --connect-timeout 10 --max-time 15 \
    --resolve "${HOST}:443:${IP}" "https://${HOST}/tlsprobe" 2>/dev/null || true)"
  code="$(curl -skS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 \
    --resolve "${HOST}:443:${IP}" "https://${HOST}/tlsprobe" 2>/dev/null || true)"
  [[ "${code}" == "200" && "${body}" == "tlsprobe-ok" ]] && break
  sleep 1
done
[[ "${code}" == "200" && "${body}" == "tlsprobe-ok" ]] \
  || fail "Domain-front HTTPS must serve Route fragment (code='${code}' body='${body}')"
pass "Domain-front HTTPS serves Workload Route fragment"

TOKEN="tls-acme-probe"
acceptance_data_track "components/edge/persist/acme-www/.well-known/acme-challenge/${TOKEN}"
host_ssh bash -s <<REMOTE
set -euo pipefail
TOKEN_PATH=/host-volume/components/edge/persist/acme-www/.well-known/acme-challenge/${TOKEN}
mkdir -p "\$(dirname "\${TOKEN_PATH}")"
printf '%s\n' '${TOKEN}' >"\${TOKEN_PATH}"
chown -R platform:platform /host-volume/components/edge/persist/acme-www
REMOTE
acme_body="$(curl -sS --connect-timeout 10 --max-time 15 \
  -H "Host: ${HOST}" "http://${IP}/.well-known/acme-challenge/${TOKEN}")"
[[ "${acme_body}" == "${TOKEN}" ]] || fail "ACME path on :80 broken after Route attach (got '${acme_body}')"
pass "ACME challenge path remains reachable on :80"

clear_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 \
  -H "Host: ${HOST}" "http://${IP}/" || true)"
[[ "${clear_code}" == "301" || "${clear_code}" == "302" ]] \
  || fail "cleartext / should redirect via Domain front (got HTTP ${clear_code})"
pass "No cleartext Workload proxy on :80"
