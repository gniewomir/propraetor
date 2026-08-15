#!/usr/bin/env bash
# Acceptance Test: path zip Source extract on a Deployed Host (ADR-0053).
# Case-generated Artifact zip (no committed blob). URI obtain stays Unit-only.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"
command -v zip >/dev/null || fail "zip required to generate path zip fixture"

FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=zip-path-src
ENV_SLUG="${PLATFORM_ENV:-test}"
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

command -v python3 >/dev/null || fail "python3 required"
ART="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/wl-zip-path-art.XXXXXX")"
cleanup_art() {
  rm -rf "${ART}"
  acceptance_wl_cleanup
}
trap cleanup_art EXIT

mkdir -p "${ART}/www"
printf '{ "directories": { "www": "static" } }\n' >"${ART}/provides.json"
printf '{ "database": false, "cache": false }\n' >"${ART}/requires.json"
printf 'from-acceptance-path-zip\n' >"${ART}/www/index.html"
mkdir -p "${FIX_DIR}/${WL}"
(cd "${ART}" && zip -qr "${FIX_DIR}/${WL}/artifact.zip" .)
printf '{}\n' >"${FIX_DIR}/${WL}/binding.json"
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "stop",
  "source": "artifact.zip"
}
EOF
[[ ! -f "${FIX_DIR}/${WL}/provides.json" ]] \
  || fail "zip Environment tree must not contain provides.json"
[[ ! -f "${FIX_DIR}/${WL}/requires.json" ]] \
  || fail "zip Environment tree must not contain requires.json"

host_ssh bash -s <<REMOTE
set -euo pipefail
rm -rf /host-volume/workloads/${WL}
REMOTE

"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"

host_ssh "grep -Fxq from-acceptance-path-zip /host-volume/workloads/${WL}/www/index.html" \
  || fail "path zip Provides directories must materialize on Host"
host_ssh "grep -Fq static /host-volume/workloads/${WL}/provides.json" \
  || fail "path zip Artifact Provides must land on Host"
host_ssh "test -f /host-volume/workloads/${WL}/requires.json" \
  || fail "path zip Artifact Requires must land on Host"
host_ssh "test -f /host-volume/workloads/${WL}/artifact.zip" \
  || fail "path zip must remain on Host as Environment bag"
host_ssh "test -f /host-volume/workloads/${WL}/manifest.json" \
  || fail "path zip Manifest must remain Environment SoT"
pass "path zip Source materializes Artifact on Host and keeps the zip"

echo "All path zip Source Acceptance checks passed."
