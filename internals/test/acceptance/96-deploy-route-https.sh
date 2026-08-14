#!/usr/bin/env bash
# Acceptance Test: Deploy alone leaves Route-backed HTTPS healthy (ADR-0043 / #182).
# Materializes a Route-backed Workload into Environment SoT, runs the Deploy ladder
# (ensure.sh), then asserts Edge is healthy and Domain-front HTTPS serves the Route —
# without calling the Edge Route fulfillment helper (that helper is Intent-transition
# composition only, not the path that makes Deploy green).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ROUTE_FQDN="$(acceptance_route_fqdn)"
if [[ -z "${ROUTE_FQDN}" ]]; then
  echo "SOFT-SKIP: empty Domain want-list — no FQDN for Deploy-alone Route HTTPS proof"
  exit 0
fi

WL=static-site
EXAMPLE_SRC="${REPO_ROOT}/environments/example/${WL}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

[[ -d "${EXAMPLE_SRC}" ]] || fail "missing teaching example at environments/example/${WL}"
acceptance_assert_artifact_tree "${EXAMPLE_SRC}" "example ${WL}"

rm -rf "${FIX_DIR:?}/${WL:?}"
cp -R "${EXAMPLE_SRC}" "${FIX_DIR}/${WL}"
# Teaching fragment is Binding-attached, not copied to an FQDN filename.
acceptance_bind_route_fragment \
  "${FIX_DIR}/${WL}" "routes/site.conf.example" "${ROUTE_FQDN}"

# Full Deploy with the Workload in Environment SoT — Mirror + both Component Setup slots.
"${REPO_ROOT}/internals/ensure.sh" --env "${PLATFORM_ENV:-test}"

# Edge healthy after Deploy (no manual Edge restart / fulfillment helper).
acceptance_wait_user_unit_active edge-pod.service 60 \
  || fail "Deploy must leave edge-pod.service active"
acceptance_wait_user_unit_active edge-nginx.service 60 \
  || fail "Deploy must leave edge-nginx.service active"
front_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 \
  "http://${IP}/" 2>/dev/null || true)"
[[ "${front_code}" =~ ^[0-9]{3}$ ]] \
  || fail "Deploy must leave Edge front door answering on :80 (got '${front_code}')"
pass "Deploy leaves Edge healthy (units active, front door answers)"

# Route fulfillment landed via post-workloads on the Deploy ladder.
installed="$(host_ssh \
  "cat /var/lib/host-volume/data/components/edge/routes/${WL}--${ROUTE_FQDN}.conf")"
printf '%s\n' "${installed}" | grep -qE "proxy_pass[[:space:]]+http://${WL}" \
  || fail "Deploy post-workloads must fulfill Route proxying to Workload basename"
pass "Deploy fulfilled Route-backed Workload Route (${ROUTE_FQDN})"

# Workload units from Deploy Workload Setup.
acceptance_wait_user_unit_active "${WL}-pod.service" 90 \
  || fail "Deploy must leave ${WL}-pod.service active"
acceptance_wait_user_unit_active "${WL}-web.service" 90 \
  || fail "Deploy must leave ${WL}-web.service active"

body=""
code=""
for _ in $(seq 1 45); do
  body="$(curl -skS --connect-timeout 10 --max-time 15 \
    --resolve "${ROUTE_FQDN}:443:${IP}" "https://${ROUTE_FQDN}/" 2>/dev/null || true)"
  code="$(curl -skS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 \
    --resolve "${ROUTE_FQDN}:443:${IP}" "https://${ROUTE_FQDN}/" 2>/dev/null || true)"
  [[ "${code}" == "200" ]] && break
  sleep 1
done
[[ "${code}" == "200" ]] \
  || fail "Deploy-alone Domain-front HTTPS must serve Route-backed Workload (code='${code}' body='${body}')"
pass "Deploy alone serves Route-backed HTTPS without fulfillment helper"
