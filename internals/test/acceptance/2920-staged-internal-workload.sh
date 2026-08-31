#!/usr/bin/env bash
# Acceptance Test: staged internal Workload lands Artifact on Deployed Host (ADR-0059 / #265).
# Prep stages content-addressed zip; Mirror extracts Provides and retains staged zip on Host.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=staged-internal
ENV_SLUG="${PLATFORM_ENV:-test}"
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

mkdir -p "${FIX_DIR}/${WL}/www" "${FIX_DIR}/${WL}/systemd"
printf '{ "directories": { "www": "static", "systemd": "units" } }\n' \
  >"${FIX_DIR}/${WL}/provides.json"
printf '{ "database": false, "cache": false }\n' >"${FIX_DIR}/${WL}/requires.json"
printf '{}\n' >"${FIX_DIR}/${WL}/binding.json"
printf 'from-acceptance-staged-internal\n' >"${FIX_DIR}/${WL}/www/index.html"
cat >"${FIX_DIR}/${WL}/systemd/${WL}.container" <<EOF
[Unit]
Description=Propraetor staged internal Workload probe

[Container]
Image=docker.io/library/busybox:1.36
ContainerName=${WL}
Network=service-network.network
Entrypoint=/bin/sleep
Exec=infinity

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "stop",
  "source": "internal"
}
EOF

host_ssh bash -s <<REMOTE
set -euo pipefail
rm -rf /host-volume/workloads/${WL}
REMOTE

acceptance_prep_env "${ENV_SLUG}"
STAGED_ZIP="$(acceptance_staged_zip_basename "${FIX_DIR}" "${WL}")"
[[ "${STAGED_ZIP}" == ${WL}-*.zip ]] \
  || fail "staged zip must be content-addressed (${WL}-<sha256>.zip), got ${STAGED_ZIP}"

"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"

host_ssh "grep -Fxq from-acceptance-staged-internal /host-volume/workloads/${WL}/www/index.html" \
  || fail "internal Provides directories must materialize on Host"
host_ssh "test -f /host-volume/workloads/${WL}/systemd/${WL}.container" \
  || fail "internal Provides directories must materialize systemd bag"
host_ssh "grep -Fq static /host-volume/workloads/${WL}/provides.json" \
  || fail "internal Artifact Provides must land on Host"
host_ssh "test -f /host-volume/workloads/${WL}/requires.json" \
  || fail "internal Artifact Requires must land on Host"
host_ssh "test -f /host-volume/workloads/${WL}/${STAGED_ZIP}" \
  || fail "content-addressed staged zip must be retained on Host (${STAGED_ZIP})"
host_ssh "python3 -c \"
import json
m=json.load(open('/host-volume/workloads/${WL}/manifest.json'))
assert m.get('source')=='internal', m
\"" || fail "Manifest source must remain internal on Host"
[[ "$(python3 -c "import json; print(json.load(open('${FIX_DIR}/${WL}/manifest.json'))['source'])")" == "internal" ]] \
  || fail "operator SoT Manifest source must stay internal"
pass "staged internal Workload materializes Artifact on Host and retains content-addressed zip"

echo "All staged internal Workload Acceptance checks passed."
