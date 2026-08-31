#!/usr/bin/env bash
# Unit tests: Mirror Host half — projects via workload_project_to_host (#204 / #228 / ADR-0059).
# Seam: ensure-mirror-host.sh (shared projection per Workload).
# Offline: temp Host Volume + staged Environment Workloads + Artifact staging.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST_SCRIPT="${REPO_ROOT}/internals/host-scripts/ensure-mirror-host.sh"
# shellcheck source=../../lib/artifact/staging.sh
source "${REPO_ROOT}/internals/lib/artifact/staging.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/ensure-mirror.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

HV="${TMP}/host-volume"
STAGE="${TMP}/stage"
mkdir -p "${HV}" "${STAGE}/lib"
# shellcheck source=../lib/workload/project-ship.sh
source "${REPO_ROOT}/internals/lib/workload/project-ship.sh"
workload_project_stage_ship_inventory "${STAGE}/lib" \
  || fail "projection ship inventory must stage Mirror libs"

cp "${HOST_SCRIPT}" "${TMP}/mirror-run.sh"
chmod +x "${TMP}/mirror-run.sh"
export HV_ROOT="${HV}"

mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TMP}/bin/chown"
export PATH="${TMP}/bin:${PATH}"

USER_NAME="$(id -un)"
ENV_ROOT="${STAGE}/workloads"

stage_artifact_zip() {
  local basename="${1:?}"
  local art_dir="${2:?}"
  local zip_file="${TMP}/mirror-${basename}.zip"

  (cd "${art_dir}" && zip -qr "${zip_file}" .)
  artifact_staging_write "${ENV_ROOT}" "${basename}" "${zip_file}" >/dev/null
}

write_internal_stubs() {
  local tree="$1"
  mkdir -p "${tree}/systemd"
  printf '{}\n' >"${tree}/provides.json"
  printf '{ "database": false, "cache": false }\n' >"${tree}/requires.json"
  printf '{}\n' >"${tree}/binding.json"
  printf '[Container]\nImage=localhost/stub\n' >"${tree}/systemd/stub.container"
}

# Seed an orphan on the Host that must survive Mirror
mkdir -p "${HV}/workloads/orphan-left/routes" "${HV}/workloads/orphan-left/persist"
printf '{"intent":"run","source":"internal"}\n' >"${HV}/workloads/orphan-left/manifest.json"
printf 'keep-orphan\n' >"${HV}/workloads/orphan-left/routes/orphan.conf"
printf 'durable\n' >"${HV}/workloads/orphan-left/persist/state.bin"

# --- internal Source: Environment bag + Provides directories ---
ALPHA_ART="${TMP}/alpha-art"
mkdir -p "${STAGE}/workloads/alpha/routes" \
  "${STAGE}/workloads/alpha/www/usage" \
  "${STAGE}/workloads/alpha/scripts" \
  "${ALPHA_ART}/routes" \
  "${ALPHA_ART}/www/usage" \
  "${ALPHA_ART}/scripts" \
  "${ALPHA_ART}/systemd"
write_internal_stubs "${STAGE}/workloads/alpha"
cat >"${STAGE}/workloads/alpha/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal"
}
EOF
cat >"${STAGE}/workloads/alpha/provides.json" <<'EOF'
{
  "directories": {
    "www": "static site",
    "scripts": "job scripts",
    "routes": "edge fragments"
  }
}
EOF
printf 'route-a\n' >"${STAGE}/workloads/alpha/routes/a.conf"
printf 'home\n' >"${STAGE}/workloads/alpha/www/index.html"
printf 'nested\n' >"${STAGE}/workloads/alpha/www/usage/index.html"
printf '#!/bin/bash\necho ok\n' >"${STAGE}/workloads/alpha/scripts/alpha-job.sh"
cp -a "${STAGE}/workloads/alpha/provides.json" "${ALPHA_ART}/provides.json"
cp -a "${STAGE}/workloads/alpha/requires.json" "${ALPHA_ART}/requires.json"
cp -a "${STAGE}/workloads/alpha/systemd/." "${ALPHA_ART}/systemd/"
cp -a "${STAGE}/workloads/alpha/routes/." "${ALPHA_ART}/routes/"
cp -a "${STAGE}/workloads/alpha/www/." "${ALPHA_ART}/www/"
cp -a "${STAGE}/workloads/alpha/scripts/." "${ALPHA_ART}/scripts/"
stage_artifact_zip "alpha" "${ALPHA_ART}"

# Manifest-less staged Workload must still be upserted (ADR-0047)
mkdir -p "${STAGE}/workloads/gamma/notes"
printf 'draft\n' >"${STAGE}/workloads/gamma/notes/idea.md"
printf 'secret-link-target\n' >"${STAGE}/workloads/gamma/target.txt"
ln -s target.txt "${STAGE}/workloads/gamma/link-to-target"
mkdir -p "${STAGE}/workloads/gamma/www/.well-known"
printf 'acme\n' >"${STAGE}/workloads/gamma/www/.well-known/probe"

# Pre-existing Host tree for alpha that Mirror must update (upsert)
mkdir -p "${HV}/workloads/alpha/routes"
printf '{"intent":"stop","source":"internal"}\n' >"${HV}/workloads/alpha/manifest.json"
printf 'stale\n' >"${HV}/workloads/alpha/routes/stale.conf"
printf 'old-a\n' >"${HV}/workloads/alpha/routes/a.conf"

cp "${TMP}/mirror-run.sh" "${STAGE}/ensure-mirror-host.sh"
bash "${STAGE}/ensure-mirror-host.sh" "${USER_NAME}" \
  || fail "ensure-mirror-host failed for internal Workloads"

python3 - "${HV}/workloads/alpha/manifest.json" <<'PY' || fail "alpha Manifest not upserted"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m.get("intent") == "run" and m.get("source") == "internal", m
PY
grep -Fxq 'route-a' "${HV}/workloads/alpha/routes/a.conf" \
  || fail "alpha route not materialized"
grep -Fxq 'home' "${HV}/workloads/alpha/www/index.html" \
  || fail "alpha www root not materialized"
grep -Fxq 'nested' "${HV}/workloads/alpha/www/usage/index.html" \
  || fail "alpha nested www not materialized"
grep -Fq 'echo ok' "${HV}/workloads/alpha/scripts/alpha-job.sh" \
  || fail "alpha scripts not materialized"
[[ ! -e "${HV}/workloads/alpha/routes/stale.conf" ]] \
  || fail "stale authored file must be pruned within Mirrored tree"
grep -Fq 'static site' "${HV}/workloads/alpha/provides.json" \
  || fail "alpha Provides must land on Host"
staged_alpha_zip="$(artifact_staging_read "${ENV_ROOT}" "alpha")"
[[ -f "${HV}/workloads/alpha/$(basename "${staged_alpha_zip}")" ]] \
  || fail "alpha staged zip must be retained on Host"
pass "Mirror materializes internal Source + Provides directories"

# Leaves orphans alone (definition tree + durable data)
[[ -f "${HV}/workloads/orphan-left/manifest.json" ]] \
  || fail "Mirror must leave orphan definition tree"
grep -Fxq 'keep-orphan' "${HV}/workloads/orphan-left/routes/orphan.conf" \
  || fail "orphan routes must be untouched"
grep -Fxq 'durable' "${HV}/workloads/orphan-left/persist/state.bin" \
  || fail "orphan durable data must be untouched"
[[ -d "${HV}/workloads/alpha/persist" ]] \
  || fail "Mirror must auto-create empty Persist for Environment Workloads"
[[ -d "${HV}/workloads/gamma/persist" ]] \
  || fail "Mirror must auto-create Persist for Manifest-less bags"
pass "Mirror leaves orphan Host trees alone"

# Manifest-less bag, hidden paths, and preserved symlinks
[[ ! -f "${HV}/workloads/gamma/manifest.json" ]] \
  || fail "gamma must remain Manifest-less"
grep -Fxq 'draft' "${HV}/workloads/gamma/notes/idea.md" \
  || fail "opaque bag extras must be mirrored"
grep -Fxq 'acme' "${HV}/workloads/gamma/www/.well-known/probe" \
  || fail "in-tree hidden paths must be mirrored"
[[ -L "${HV}/workloads/gamma/link-to-target" ]] \
  || fail "symlinks must be preserved as links"
pass "Mirror upserts Manifest-less bags; preserves hidden paths and symlinks"

# Invalid Manifest present → Source resolution fails closed
rm -rf "${STAGE}/workloads"
mkdir -p "${STAGE}/workloads/bad"
printf 'not-even-json\n' >"${STAGE}/workloads/bad/manifest.json"
cp "${TMP}/mirror-run.sh" "${STAGE}/ensure-mirror-host.sh"
if bash "${STAGE}/ensure-mirror-host.sh" "${USER_NAME}" >/dev/null 2>&1; then
  fail "invalid Manifest must fail closed at Source resolution"
fi
pass "Mirror fails closed on invalid Manifest Source resolution"

# Reserved collision: root Provides pull onto dest with Manifest/Binding
rm -rf "${STAGE}/workloads"
COLLIDE_ART="${TMP}/collide-art"
mkdir -p "${STAGE}/workloads/collide/extra" "${COLLIDE_ART}/extra" "${COLLIDE_ART}/systemd"
write_internal_stubs "${STAGE}/workloads/collide"
cat >"${STAGE}/workloads/collide/manifest.json" <<'EOF'
{ "intent": "stop", "source": "internal" }
EOF
cat >"${STAGE}/workloads/collide/provides.json" <<'EOF'
{ "directories": { ".": "entire artifact root" } }
EOF
printf 'payload\n' >"${STAGE}/workloads/collide/extra/file.txt"
cp -a "${STAGE}/workloads/collide/provides.json" "${COLLIDE_ART}/provides.json"
cp -a "${STAGE}/workloads/collide/requires.json" "${COLLIDE_ART}/requires.json"
cp -a "${STAGE}/workloads/collide/systemd/." "${COLLIDE_ART}/systemd/"
cp -a "${STAGE}/workloads/collide/extra/." "${COLLIDE_ART}/extra/"
stage_artifact_zip "collide" "${COLLIDE_ART}"
cp "${TMP}/mirror-run.sh" "${STAGE}/ensure-mirror-host.sh"
if bash "${STAGE}/ensure-mirror-host.sh" "${USER_NAME}" >/dev/null 2>&1; then
  fail "root Provides directories onto reserved Host files must fail closed"
fi
pass "Mirror fails closed on reserved Provides destination collision"

# --- zip Source: Environment holds Manifest+Binding; Artifact content from staging ---
rm -rf "${STAGE}/workloads"
ZIP_ROOT="${TMP}/zip-artifact"
ZIP_DIR="${TMP}/zip-http"
mkdir -p "${ZIP_ROOT}/systemd" "${ZIP_ROOT}/www" "${ZIP_DIR}"
cat >"${ZIP_ROOT}/provides.json" <<'EOF'
{
  "directories": {
    "systemd": "units",
    "www": "static"
  }
}
EOF
printf '{ "database": false, "cache": false }\n' >"${ZIP_ROOT}/requires.json"
printf 'from-zip-unit\n' >"${ZIP_ROOT}/systemd/zippy.container"
printf 'from-zip-www\n' >"${ZIP_ROOT}/www/index.html"
(cd "${ZIP_ROOT}" && zip -qr "${ZIP_DIR}/artifact.zip" .)
ZIP_URI="http://127.0.0.1:1/artifact.zip"

mkdir -p "${STAGE}/workloads/zippy"
printf '{}\n' >"${STAGE}/workloads/zippy/binding.json"
cat >"${STAGE}/workloads/zippy/manifest.json" <<EOF
{
  "intent": "run",
  "source": "${ZIP_URI}"
}
EOF
stage_artifact_zip "zippy" "${ZIP_ROOT}"

cp "${TMP}/mirror-run.sh" "${STAGE}/ensure-mirror-host.sh"
bash "${STAGE}/ensure-mirror-host.sh" "${USER_NAME}" \
  || fail "ensure-mirror-host failed for staged zip Source"

grep -Fxq 'from-zip-unit' \
  "${HV}/workloads/zippy/systemd/zippy.container" \
  || fail "staged zip Provides directories must materialize systemd"
grep -Fxq 'from-zip-www' "${HV}/workloads/zippy/www/index.html" \
  || fail "staged zip Provides directories must materialize www"
grep -Fq 'units' "${HV}/workloads/zippy/provides.json" \
  || fail "staged zip Artifact Provides must land on Host"
grep -Fq 'database' "${HV}/workloads/zippy/requires.json" \
  || fail "staged zip Artifact Requires must land on Host"
python3 - "${HV}/workloads/zippy/manifest.json" <<'PY' || fail "zip Manifest must remain Environment SoT"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m.get("intent") == "run"
assert str(m.get("source", "")).endswith(".zip")
PY
[[ -f "${HV}/workloads/zippy/binding.json" ]] \
  || fail "zip Environment Binding must remain on Host"
staged_zippy_zip="$(artifact_staging_read "${ENV_ROOT}" "zippy")"
[[ -f "${HV}/workloads/zippy/$(basename "${staged_zippy_zip}")" ]] \
  || fail "staged zip must be retained on Host with content-addressed name"
pass "Mirror materializes staged zip Source via Provides directories"

# --- path zip Source: same Artifact, local manifest path, staged zip on Host ---
rm -rf "${STAGE}/workloads"
mkdir -p "${STAGE}/workloads/zippath"
printf '{}\n' >"${STAGE}/workloads/zippath/binding.json"
cat >"${STAGE}/workloads/zippath/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "artifact.zip"
}
EOF
stage_artifact_zip "zippath" "${ZIP_ROOT}"

cp "${TMP}/mirror-run.sh" "${STAGE}/ensure-mirror-host.sh"
bash "${STAGE}/ensure-mirror-host.sh" "${USER_NAME}" \
  || fail "ensure-mirror-host failed for path zip Source"
grep -Fxq 'from-zip-www' "${HV}/workloads/zippath/www/index.html" \
  || fail "staged path zip Provides directories must materialize www"
staged_zippath_zip="$(artifact_staging_read "${ENV_ROOT}" "zippath")"
[[ -f "${HV}/workloads/zippath/$(basename "${staged_zippath_zip}")" ]] \
  || fail "staged zip must be retained on Host with content-addressed name"
pass "Mirror materializes path zip Source via staged Artifact cache"

echo "All ensure-mirror-host offline tests passed."
