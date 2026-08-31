#!/usr/bin/env bash
# Acceptance Test: local Source stages Project root materials (ADR-0058 / #259).
# Case-local Projects root + Artifact path; Environment tree is Manifest+Binding only.
# Operator SoT path is Projects-root-relative; staged Host Manifest is Project-root-relative.
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
REPO="${PROJ}/repo"
cleanup_local() {
  rm -rf "${PROJ}"
  acceptance_wl_cleanup
}
trap cleanup_local EXIT

# Materials = Project root (git toplevel); Artifact at path inside it.
# Projects root also holds an unrelated tree that must not be staged.
mkdir -p "${REPO}/pkg/${WL}/www" "${REPO}/pkg/${WL}/systemd" \
  "${REPO}/in-repo-sibling" "${PROJ}/unrelated"
printf 'unrelated\n' >"${PROJ}/unrelated/keep.txt"
printf 'in-repo\n' >"${REPO}/in-repo-sibling/keep.txt"
printf '{ "directories": { "www": "static", "systemd": "units" } }\n' \
  >"${REPO}/pkg/${WL}/provides.json"
printf '{ "database": false, "cache": false }\n' \
  >"${REPO}/pkg/${WL}/requires.json"
printf 'from-acceptance-local\n' >"${REPO}/pkg/${WL}/www/index.html"
cat >"${REPO}/pkg/${WL}/systemd/${WL}.container" <<EOF
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
git -C "${REPO}" init --quiet
git -C "${REPO}" config user.email "acceptance@example.com"
git -C "${REPO}" config user.name "acceptance"
git -C "${REPO}" add .
git -C "${REPO}" commit --quiet -m init

mkdir -p "${FIX_DIR}/${WL}"
printf '{}\n' >"${FIX_DIR}/${WL}/binding.json"
cat >"${FIX_DIR}/${WL}/manifest.json" <<EOF
{
  "intent": "stop",
  "source": { "kind": "local", "path": "repo/pkg/${WL}" }
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

PROPRAETOR_PROJECTS_ROOT="${PROJ}" acceptance_prep_env "${ENV_SLUG}"
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
host_ssh "test ! -e /host-volume/workloads/${WL}/in-repo-sibling" \
  || fail "local must not land materials siblings on Host Workload tree"
host_ssh "test ! -e /host-volume/workloads/${WL}/unrelated" \
  || fail "local must not land Projects-root siblings on Host Workload tree"
host_ssh "test -f /host-volume/workloads/${WL}/manifest.json" \
  || fail "local Manifest must remain Environment SoT"
host_ssh "python3 -c \"
import json
m=json.load(open('/host-volume/workloads/${WL}/manifest.json'))
assert m['source']['kind']=='local'
assert m['source']['path']=='pkg/${WL}', m['source']
\"" || fail "Host Manifest path must be Project-root-relative after stage rewrite"
[[ "$(python3 -c "import json; print(json.load(open('${FIX_DIR}/${WL}/manifest.json'))['source']['path'])")" == "repo/pkg/${WL}" ]] \
  || fail "operator SoT Manifest path must stay Projects-root-relative"
pass "local Source materializes Artifact from staged Project root"

echo "All local Source Acceptance checks passed."
