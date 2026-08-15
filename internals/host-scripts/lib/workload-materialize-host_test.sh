#!/usr/bin/env bash
# Unit tests: Host Workload materialize projection (ADR-0053 / #204).
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
TREE="${TMP}/env-wl"
mkdir -p "${TREE}"
printf '{}\n' >"${TREE}/binding.json"
cat >"${TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": "http://127.0.0.1:1/missing.zip" }
EOF

# Zip Environment must not already hold Artifact contracts (fail before fetch).
printf '{ "database": false }\n' >"${TREE}/requires.json"
if err="$(workload_materialize_tree "${TREE}" "${OUT}" 2>&1)"; then
  fail "zip Environment requires.json must fail closed before zip obtain"
fi
printf '%s\n' "${err}" | grep -q 'requires.json' \
  || fail "zip dest collision must name requires.json, got: ${err}"
printf '%s\n' "${err}" | grep -Eqi 'fetch|curl' \
  && fail "zip dest collision must fail before fetch, got: ${err}"
pass "zip Environment requires.json fails closed before fetch"

rm -f "${TREE}/requires.json"
printf '{}\n' >"${TREE}/provides.json"
if err="$(workload_materialize_tree "${TREE}" "${OUT}" 2>&1)"; then
  fail "zip Environment provides.json must fail closed before zip obtain"
fi
printf '%s\n' "${err}" | grep -q 'provides.json' \
  || fail "zip dest collision must name provides.json, got: ${err}"
pass "zip Environment provides.json fails closed before fetch"

# --- path zip Source: extract + keep .zip on Host tree ---
PATH_TREE="${TMP}/path-wl"
PATH_ART="${TMP}/path-art"
mkdir -p "${PATH_ART}/www" "${PATH_ART}/systemd" "${PATH_TREE}"
printf '{ "directories": { "www": "static", "systemd": "units" } }\n' >"${PATH_ART}/provides.json"
printf '{ "database": false }\n' >"${PATH_ART}/requires.json"
printf 'from-path-zip\n' >"${PATH_ART}/www/index.html"
printf '[Container]\nImage=localhost/path\n' >"${PATH_ART}/systemd/path.container"
(cd "${PATH_ART}" && zip -qr "${PATH_TREE}/artifact.zip" .)
printf '{}\n' >"${PATH_TREE}/binding.json"
cat >"${PATH_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": "artifact.zip" }
EOF
rm -rf "${OUT}"
workload_materialize_tree "${PATH_TREE}" "${OUT}" \
  || fail "path zip materialize must succeed"
grep -Fxq 'from-path-zip' "${OUT}/www/index.html" \
  || fail "path zip Provides directories must materialize"
[[ -f "${OUT}/systemd/path.container" ]] \
  || fail "path zip must materialize systemd bag"
grep -Fq 'static' "${OUT}/provides.json" \
  || fail "path zip Artifact Provides must land on Host"
[[ -f "${OUT}/artifact.zip" ]] \
  || fail "path zip must remain on Host as Environment bag"
pass "path zip materialize keeps zip and applies Provides"

# --- path zip peel ---
WRAP_TREE="${TMP}/wrap-wl"
WRAP_ART="${TMP}/wrap-art"
mkdir -p "${WRAP_ART}/bundle/www" "${WRAP_ART}/bundle/systemd" "${WRAP_TREE}"
printf '{ "directories": { "www": "static", "systemd": "units" } }\n' >"${WRAP_ART}/bundle/provides.json"
printf '{ "database": false }\n' >"${WRAP_ART}/bundle/requires.json"
printf 'from-peel\n' >"${WRAP_ART}/bundle/www/index.html"
printf '[Container]\nImage=localhost/peel\n' >"${WRAP_ART}/bundle/systemd/peel.container"
(cd "${WRAP_ART}" && zip -qr "${WRAP_TREE}/wrapped.zip" bundle)
printf '{}\n' >"${WRAP_TREE}/binding.json"
cat >"${WRAP_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": "wrapped.zip" }
EOF
rm -rf "${OUT}"
workload_materialize_tree "${WRAP_TREE}" "${OUT}" \
  || fail "wrapped path zip materialize must succeed"
grep -Fxq 'from-peel' "${OUT}/www/index.html" \
  || fail "peeled zip Provides directories must materialize"
[[ -f "${OUT}/systemd/peel.container" ]] \
  || fail "peeled zip must materialize systemd bag"
pass "path zip materialize peels sole wrapper with Provides"

# --- outbound symlink fail-closed ---
ln -s /tmp "${PATH_TREE}/escape"
if workload_materialize_tree "${PATH_TREE}" "${OUT}" >/dev/null 2>&1; then
  fail "outbound Workload symlink must fail materialize"
fi
rm -f "${PATH_TREE}/escape"
pass "materialize refuses outbound Workload symlink"

# --- Persist reserved: Environment / Artifact must not ship persist/ ---
PERS_TREE="${TMP}/persist-wl"
mkdir -p "${PERS_TREE}/persist"
printf '{}\n' >"${PERS_TREE}/binding.json"
cat >"${PERS_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
printf '{ "directories": { "www": "www" } }\n' >"${PERS_TREE}/provides.json"
printf '{ "database": false }\n' >"${PERS_TREE}/requires.json"
mkdir -p "${PERS_TREE}/www"
if err="$(workload_materialize_tree "${PERS_TREE}" "${OUT}" 2>&1)"; then
  fail "Environment persist/ must fail closed"
fi
printf '%s\n' "${err}" | grep -Eqi 'persist' \
  || fail "Environment persist rejection unclear: ${err}"
pass "materialize refuses Environment persist/"

# --- systemd filename merge collision fails closed ---
MERGE_ENV="${TMP}/merge-env"
MERGE_ART="${TMP}/merge-art"
mkdir -p "${MERGE_ENV}/systemd" "${MERGE_ART}/systemd"
printf '{}\n' >"${MERGE_ENV}/binding.json"
cat >"${MERGE_ENV}/manifest.json" <<'MAN'
{ "intent": "run", "source": "artifact.zip" }
MAN
printf '[Container]\nImage=localhost/env\n' >"${MERGE_ENV}/systemd/shared.container"
printf '{ "directories": { "systemd": "units" } }\n' >"${MERGE_ART}/provides.json"
printf '{ "database": false }\n' >"${MERGE_ART}/requires.json"
printf '[Container]\nImage=localhost/art\n' >"${MERGE_ART}/systemd/shared.container"
(cd "${MERGE_ART}" && zip -qr "${MERGE_ENV}/artifact.zip" .)
rm -rf "${OUT}"
if workload_materialize_tree "${MERGE_ENV}" "${OUT}" >/dev/null 2>&1; then
  fail "systemd/ filename collision must fail closed"
fi
pass "systemd/ filename merge collision fails closed"

# --- retired quadlets/ on Environment fails closed ---
Q_TREE="${TMP}/quadlets-wl"
mkdir -p "${Q_TREE}/quadlets" "${Q_TREE}/systemd"
printf '{}\n' >"${Q_TREE}/binding.json"
printf '{}\n' >"${Q_TREE}/provides.json"
printf '{ "database": false }\n' >"${Q_TREE}/requires.json"
cat >"${Q_TREE}/manifest.json" <<'MAN'
{ "intent": "run", "source": "internal" }
MAN
printf '[Container]\nImage=localhost/x\n' >"${Q_TREE}/systemd/ok.container"
if workload_materialize_tree "${Q_TREE}" "${OUT}" >/dev/null 2>&1; then
  fail "retired quadlets/ must fail materialize"
fi
pass "retired quadlets/ on Environment fails closed"

echo "All workload-materialize-host offline tests passed."
