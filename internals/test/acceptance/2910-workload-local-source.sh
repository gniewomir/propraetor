#!/usr/bin/env bash
# Acceptance Test: local Source stages Projects root materials (ADR-0058 / #259).
# Case-local Projects root + Artifact path; Environment tree is Manifest+Binding only.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=local-path-src
ENV_SLUG="${PLATFORM_ENV:-test}"
acceptance_wl_track "${WL}"

PROJ="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/wl-local-projects.XXXXXX")"
cleanup_local() {
  rm -rf "${PROJ}"
  acceptance_wl_cleanup
}
trap cleanup_local EXIT

# Materials = whole Projects root; Artifact at relative path inside it.
mkdir -p "${PROJ}/pkg/${WL}/www" "${PROJ}/pkg/${WL}/systemd" "${PROJ}/sibling"
printf 'sibling-marker\n' >"${PROJ}/sibling/keep.txt"
printf '{ "directories": { "www": "static", "systemd": "units" } }\n' \
  >"${PROJ}/pkg/${WL}/provides.json"
printf '{ "database": false, "cache": false }\n' \
  >"${PROJ}/pkg/${WL}/requires.json"
printf 'from-acceptance-local\n' >"${PROJ}/pkg/${WL}/www/index.html"
cat >"${PROJ}/pkg/${WL}/systemd/${WL}.container" <<EOF
[Unit]
Description=Propraetor local Source probe

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

mkdir -p "${FIX_DIR}/${WL}"
printf '{}\n' >"${FIX_DIR}/${WL}/binding.json"
cat >"${FIX_DIR}/${WL}/manifest.json" <<EOF
{
  "intent": "stop",
  "source": { "kind": "local", "path": "pkg/${WL}" }
}
EOF
[[ ! -f "${FIX_DIR}/${WL}/provides.json" ]] \
  || fail "local Environment tree must not contain provides.json"
[[ ! -f "${FIX_DIR}/${WL}/requires.json" ]] \
  || fail "local Environment tree must not contain requires.json"

host_ssh bash -s <<REMOTE
set -euo pipefail
rm -rf /host-volume/workloads/${WL}
REMOTE

PROPRAETOR_PROJECTS_ROOT="${PROJ}" \
  "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"

host_ssh "grep -Fxq from-acceptance-local /host-volume/workloads/${WL}/www/index.html" \
  || fail "local Provides directories must materialize on Host"
host_ssh "test -f /host-volume/workloads/${WL}/systemd/${WL}.container" \
  || fail "local Provides directories must materialize systemd bag"
host_ssh "grep -Fq static /host-volume/workloads/${WL}/provides.json" \
  || fail "local Artifact Provides must land on Host"
host_ssh "test -f /host-volume/workloads/${WL}/requires.json" \
  || fail "local Artifact Requires must land on Host"
host_ssh "test ! -e /host-volume/workloads/${WL}/sibling" \
  || fail "local must not land materials siblings on Host Workload tree"
host_ssh "test -f /host-volume/workloads/${WL}/manifest.json" \
  || fail "local Manifest must remain Environment SoT"
pass "local Source materializes Artifact from staged Projects root"

echo "All local Source Acceptance checks passed."
