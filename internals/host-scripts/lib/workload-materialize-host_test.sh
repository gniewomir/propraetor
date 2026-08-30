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
printf '{ "database": false, "cache": false }\n' >"${TREE}/requires.json"
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
printf '{ "database": false, "cache": false }\n' >"${PATH_ART}/requires.json"
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
printf '{ "database": false, "cache": false }\n' >"${WRAP_ART}/bundle/requires.json"
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
printf '{ "database": false, "cache": false }\n' >"${PERS_TREE}/requires.json"
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
printf '{ "database": false, "cache": false }\n' >"${MERGE_ART}/requires.json"
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
printf '{ "database": false, "cache": false }\n' >"${Q_TREE}/requires.json"
cat >"${Q_TREE}/manifest.json" <<'MAN'
{ "intent": "run", "source": "internal" }
MAN
printf '[Container]\nImage=localhost/x\n' >"${Q_TREE}/systemd/ok.container"
if workload_materialize_tree "${Q_TREE}" "${OUT}" >/dev/null 2>&1; then
  fail "retired quadlets/ must fail materialize"
fi
pass "retired quadlets/ on Environment fails closed"

# --- local Source: staged materials + Artifact path ---
LOCAL_ENV="${TMP}/local-env"
LOCAL_MAT="${TMP}/local-mat"
LOCAL_ART_REL="pkg/inbox"
mkdir -p "${LOCAL_ENV}" "${LOCAL_MAT}/${LOCAL_ART_REL}/www" "${LOCAL_MAT}/${LOCAL_ART_REL}/systemd"
printf '{}\n' >"${LOCAL_ENV}/binding.json"
cat >"${LOCAL_ENV}/manifest.json" <<EOF
{ "intent": "run", "source": { "kind": "local", "path": "${LOCAL_ART_REL}" } }
EOF
printf '{ "directories": { "www": "static", "systemd": "units" } }\n' \
  >"${LOCAL_MAT}/${LOCAL_ART_REL}/provides.json"
printf '{ "database": false, "cache": false }\n' \
  >"${LOCAL_MAT}/${LOCAL_ART_REL}/requires.json"
printf 'from-local\n' >"${LOCAL_MAT}/${LOCAL_ART_REL}/www/index.html"
printf '[Container]\nImage=localhost/local\n' \
  >"${LOCAL_MAT}/${LOCAL_ART_REL}/systemd/local.container"
if workload_materialize_tree "${LOCAL_ENV}" "${OUT}" >/dev/null 2>&1; then
  fail "local Source without materials dir must fail closed"
fi
rm -rf "${OUT}"
workload_materialize_tree "${LOCAL_ENV}" "${OUT}" "${LOCAL_MAT}" \
  || fail "local Source materialize must succeed"
grep -Fxq 'from-local' "${OUT}/www/index.html" \
  || fail "local Provides directories must materialize"
[[ -f "${OUT}/systemd/local.container" ]] \
  || fail "local must materialize systemd bag"
[[ ! -d "${OUT}/pkg" ]] \
  || fail "local must land Artifact root only, not materials tree"
pass "local Source materialize from staged materials"

# --- git Source: stub git obtain ---
GIT_ENV="${TMP}/git-env"
GIT_STUBS="${TMP}/git-stubs"
mkdir -p "${GIT_ENV}" "${GIT_STUBS}"
printf '{}\n' >"${GIT_ENV}/binding.json"
cat >"${GIT_ENV}/manifest.json" <<'EOF'
{ "intent": "run", "source": {
  "kind": "git",
  "url": "https://example.com/repo.git",
  "commit": "0123456789abcdef0123456789abcdef01234567",
  "path": "app"
}}
EOF
cat >"${GIT_STUBS}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Emulate: git -C MATERIALS init|remote|fetch|checkout
# Args vary; last non-option after -C is the materials dir when present.
materials=""
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  if [[ "${args[$i]}" == "-C" ]]; then
    i=$((i + 1))
    materials="${args[$i]}"
  fi
  i=$((i + 1))
done
cmd=""
for a in "$@"; do
  case "$a" in
    init|remote|fetch|checkout) cmd="$a"; break ;;
  esac
done
case "${cmd}" in
  init|remote|fetch) exit 0 ;;
  checkout)
    [[ -n "${materials}" ]] || exit 1
    mkdir -p "${materials}/app/www" "${materials}/app/systemd"
    printf '{ "directories": { "www": "static", "systemd": "units" } }\n' \
      >"${materials}/app/provides.json"
    printf '{ "database": false, "cache": false }\n' \
      >"${materials}/app/requires.json"
    printf 'from-git\n' >"${materials}/app/www/index.html"
    printf '[Container]\nImage=localhost/git\n' \
      >"${materials}/app/systemd/git.container"
    exit 0
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${GIT_STUBS}/git"
rm -rf "${OUT}"
PATH="${GIT_STUBS}:${PATH}" workload_materialize_tree "${GIT_ENV}" "${OUT}" \
  || fail "git Source materialize must succeed with stub git"
grep -Fxq 'from-git' "${OUT}/www/index.html" \
  || fail "git Provides directories must materialize"
pass "git Source materialize via Host obtain"

# --- missing git binary fails closed ---
GIT_HIDE="${TMP}/nogit-path"
mkdir -p "${GIT_HIDE}"
# PATH without git: only empty dir + essential bins via system — use env -i subset.
if PATH="${GIT_HIDE}:/usr/bin:/bin" command -v git >/dev/null 2>&1; then
  pass "skip missing-git check (git still on PATH)"
else
  if PATH="${GIT_HIDE}:/usr/bin:/bin" workload_materialize_tree "${GIT_ENV}" "${OUT}" \
    >/dev/null 2>&1; then
    fail "git Source without git binary must fail closed"
  fi
  pass "git Source fails closed without git"
fi

echo "All workload-materialize-host offline tests passed."
