#!/usr/bin/env bash
# Unit tests: Host Workload materialize projection (ADR-0053 / ADR-0059 / #262).
# Seam: workload_materialize_tree.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=workload-materialize-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/workload-materialize-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/wl-materialize.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

OUT="${TMP}/out"

# Given ENV_TREE with manifest+binding, stage artifact zip under Environment root.
stage_artifact_for_tree() {
  local env_tree="${1:?}"
  local art_dir="${2:?}"
  local env_root zip_file

  env_root="$(dirname "${env_tree}")"
  zip_file="${TMP}/stage-$(basename "${env_tree}").zip"
  (cd "${art_dir}" && zip -qr "${zip_file}" .)
  artifact_staging_write "${env_root}" "$(basename "${env_tree}")" "${zip_file}" >/dev/null
}

# --- zip Environment gate: requires.json fails before staging read ---
TREE="${TMP}/env-root/zip-wl"
mkdir -p "${TREE}"
printf '{}\n' >"${TREE}/binding.json"
cat >"${TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": {"kind":"zip","uri":"http://127.0.0.1:1/missing.zip"} }
EOF
printf '{ "database": false, "cache": false }\n' >"${TREE}/requires.json"
if err="$(workload_materialize_tree "${TREE}" "${OUT}" 2>&1)"; then
  fail "zip Environment requires.json must fail closed before staging read"
fi
printf '%s\n' "${err}" | grep -q 'requires.json' \
  || fail "zip dest collision must name requires.json, got: ${err}"
printf '%s\n' "${err}" | grep -qi 'staging' \
  && fail "zip dest collision must fail before staging read, got: ${err}"
pass "zip Environment requires.json fails closed before staging read"

rm -f "${TREE}/requires.json"
printf '{}\n' >"${TREE}/provides.json"
if err="$(workload_materialize_tree "${TREE}" "${OUT}" 2>&1)"; then
  fail "zip Environment provides.json must fail closed before staging read"
fi
printf '%s\n' "${err}" | grep -q 'provides.json' \
  || fail "zip dest collision must name provides.json, got: ${err}"
pass "zip Environment provides.json fails closed before staging read"

# --- staging happy path: path-style artifact zip ---
PATH_TREE="${TMP}/env-root/path-wl"
PATH_ART="${TMP}/path-art"
mkdir -p "${PATH_ART}/www" "${PATH_ART}/systemd" "${PATH_TREE}"
printf '{ "directories": { "www": "static", "systemd": "units" } }\n' >"${PATH_ART}/provides.json"
printf '{ "database": false, "cache": false }\n' >"${PATH_ART}/requires.json"
printf 'from-path-zip\n' >"${PATH_ART}/www/index.html"
printf '[Container]\nImage=localhost/path\n' >"${PATH_ART}/systemd/path.container"
stage_artifact_for_tree "${PATH_TREE}" "${PATH_ART}"
printf '{}\n' >"${PATH_TREE}/binding.json"
cat >"${PATH_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": {"kind":"zip","path":"artifact.zip"} }
EOF
rm -rf "${OUT}"
workload_materialize_tree "${PATH_TREE}" "${OUT}" \
  || fail "staged path zip materialize must succeed"
grep -Fxq 'from-path-zip' "${OUT}/www/index.html" \
  || fail "staged path zip Provides directories must materialize"
[[ -f "${OUT}/systemd/path.container" ]] \
  || fail "staged path zip must materialize systemd bag"
grep -Fq 'static' "${OUT}/provides.json" \
  || fail "staged path zip Artifact Provides must land on Host"
staged_zip="$(artifact_staging_read "$(dirname "${PATH_TREE}")" "$(basename "${PATH_TREE}")")"
[[ -f "${OUT}/$(basename "${staged_zip}")" ]] \
  || fail "staged zip must be retained on Host with content-addressed name"
pass "staging happy path keeps zip and applies Provides"

# --- peel case (wrapped zip in staged artifact) ---
WRAP_TREE="${TMP}/env-root/wrap-wl"
WRAP_ART="${TMP}/wrap-art"
mkdir -p "${WRAP_ART}/bundle/www" "${WRAP_ART}/bundle/systemd" "${WRAP_TREE}"
printf '{ "directories": { "www": "static", "systemd": "units" } }\n' >"${WRAP_ART}/bundle/provides.json"
printf '{ "database": false, "cache": false }\n' >"${WRAP_ART}/bundle/requires.json"
printf 'from-peel\n' >"${WRAP_ART}/bundle/www/index.html"
printf '[Container]\nImage=localhost/peel\n' >"${WRAP_ART}/bundle/systemd/peel.container"
stage_artifact_for_tree "${WRAP_TREE}" "${WRAP_ART}"
printf '{}\n' >"${WRAP_TREE}/binding.json"
cat >"${WRAP_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": {"kind":"zip","path":"wrapped.zip"} }
EOF
rm -rf "${OUT}"
workload_materialize_tree "${WRAP_TREE}" "${OUT}" \
  || fail "wrapped staged zip materialize must succeed"
grep -Fxq 'from-peel' "${OUT}/www/index.html" \
  || fail "peeled zip Provides directories must materialize"
[[ -f "${OUT}/systemd/peel.container" ]] \
  || fail "peeled zip must materialize systemd bag"
pass "staged zip materialize peels sole wrapper with Provides"

# --- outbound symlink fail-closed ---
ln -s /tmp "${PATH_TREE}/escape"
if workload_materialize_tree "${PATH_TREE}" "${OUT}" >/dev/null 2>&1; then
  fail "outbound Workload symlink must fail materialize"
fi
rm -f "${PATH_TREE}/escape"
pass "materialize refuses outbound Workload symlink"

# --- Persist reserved: Environment / Artifact must not ship persist/ ---
PERS_TREE="${TMP}/env-root/persist-wl"
PERS_ART="${TMP}/persist-art"
mkdir -p "${PERS_TREE}/persist" "${PERS_ART}/www" "${PERS_ART}/systemd"
printf '{}\n' >"${PERS_TREE}/binding.json"
cat >"${PERS_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": {"kind":"internal"} }
EOF
printf '{ "directories": { "www": "www" } }\n' >"${PERS_ART}/provides.json"
printf '{ "database": false, "cache": false }\n' >"${PERS_ART}/requires.json"
printf '[Container]\nImage=localhost/x\n' >"${PERS_ART}/systemd/x.container"
stage_artifact_for_tree "${PERS_TREE}" "${PERS_ART}"
if err="$(workload_materialize_tree "${PERS_TREE}" "${OUT}" 2>&1)"; then
  fail "Environment persist/ must fail closed"
fi
printf '%s\n' "${err}" | grep -Eqi 'persist' \
  || fail "Environment persist rejection unclear: ${err}"
pass "materialize refuses Environment persist/"

# --- systemd filename merge collision fails closed ---
MERGE_ENV="${TMP}/env-root/merge-env"
MERGE_ART="${TMP}/merge-art"
mkdir -p "${MERGE_ENV}/systemd" "${MERGE_ART}/systemd"
printf '{}\n' >"${MERGE_ENV}/binding.json"
cat >"${MERGE_ENV}/manifest.json" <<'MAN'
{ "intent": "run", "source": {"kind":"zip","path":"artifact.zip"} }
MAN
printf '[Container]\nImage=localhost/env\n' >"${MERGE_ENV}/systemd/shared.container"
printf '{ "directories": { "systemd": "units" } }\n' >"${MERGE_ART}/provides.json"
printf '{ "database": false, "cache": false }\n' >"${MERGE_ART}/requires.json"
printf '[Container]\nImage=localhost/art\n' >"${MERGE_ART}/systemd/shared.container"
stage_artifact_for_tree "${MERGE_ENV}" "${MERGE_ART}"
rm -rf "${OUT}"
if workload_materialize_tree "${MERGE_ENV}" "${OUT}" >/dev/null 2>&1; then
  fail "systemd/ filename collision must fail closed"
fi
pass "systemd/ filename merge collision fails closed"

# --- retired quadlets/ on Environment fails closed ---
Q_TREE="${TMP}/env-root/quadlets-wl"
Q_ART="${TMP}/quadlets-art"
mkdir -p "${Q_TREE}/quadlets" "${Q_TREE}/systemd" "${Q_ART}/systemd"
printf '{}\n' >"${Q_TREE}/binding.json"
printf '{}\n' >"${Q_TREE}/provides.json"
printf '{ "database": false, "cache": false }\n' >"${Q_TREE}/requires.json"
cat >"${Q_TREE}/manifest.json" <<'MAN'
{ "intent": "run", "source": {"kind":"internal"} }
MAN
printf '[Container]\nImage=localhost/x\n' >"${Q_TREE}/systemd/ok.container"
printf '{ "directories": { "systemd": "units" } }\n' >"${Q_ART}/provides.json"
printf '{ "database": false, "cache": false }\n' >"${Q_ART}/requires.json"
printf '[Container]\nImage=localhost/x\n' >"${Q_ART}/systemd/ok.container"
stage_artifact_for_tree "${Q_TREE}" "${Q_ART}"
if workload_materialize_tree "${Q_TREE}" "${OUT}" >/dev/null 2>&1; then
  fail "retired quadlets/ must fail materialize"
fi
pass "retired quadlets/ on Environment fails closed"

# --- missing staging fails closed ---
MISS_TREE="${TMP}/env-root/miss-wl"
mkdir -p "${MISS_TREE}"
printf '{}\n' >"${MISS_TREE}/binding.json"
cat >"${MISS_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": {"kind":"internal"} }
EOF
if workload_materialize_tree "${MISS_TREE}" "${OUT}" >/dev/null 2>&1; then
  fail "missing staging must fail closed"
fi
pass "missing staging fails closed"

# --- missing referenced zip fails closed (staging present, zip absent) ---
BROKEN_TREE="${TMP}/env-root/broken-wl"
BROKEN_ART="${TMP}/broken-art"
mkdir -p "${BROKEN_TREE}" "${BROKEN_ART}/systemd"
printf '{}\n' >"${BROKEN_TREE}/binding.json"
cat >"${BROKEN_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": {"kind":"internal"} }
EOF
printf '{ "directories": { "systemd": "units" } }\n' >"${BROKEN_ART}/provides.json"
printf '{ "database": false, "cache": false }\n' >"${BROKEN_ART}/requires.json"
printf '[Container]\nImage=localhost/broken\n' >"${BROKEN_ART}/systemd/broken.container"
stage_artifact_for_tree "${BROKEN_TREE}" "${BROKEN_ART}"
broken_env_root="$(dirname "${BROKEN_TREE}")"
broken_basename="$(basename "${BROKEN_TREE}")"
broken_zip="$(artifact_staging_read "${broken_env_root}" "${broken_basename}")"
rm -f "${broken_zip}"
if workload_materialize_tree "${BROKEN_TREE}" "${OUT}" >/dev/null 2>&1; then
  fail "missing referenced zip must fail closed"
fi
pass "missing referenced zip fails closed"

echo "All workload-materialize-host offline tests passed."
