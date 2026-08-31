#!/usr/bin/env bash
# Unit tests: Artifact Prep (ADR-0059 / #261 / #263).
# Seam: artifact_prep_* / artifact_prep_workload.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=prep.sh
source "${REPO_ROOT}/internals/lib/artifact/prep.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/artifact-prep.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

ENV_ROOT="${TMP}/env"
WORKLOAD="${ENV_ROOT}/analytics"

zip_members() {
  python3 - "${1:?}" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as zf:
    for name in sorted(zf.namelist()):
        print(name)
PY
}

member_has() {
  local zip_path="${1:?}"
  local member="${2:?}"
  python3 - "${zip_path}" "${member}" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as zf:
    raise SystemExit(0 if sys.argv[2] in zf.namelist() else 1)
PY
}

setup_internal_workload() {
  mkdir -p "${WORKLOAD}/systemd" "${WORKLOAD}/persist"
  printf '{"intent":"run","source":{"kind":"internal"}}\n' >"${WORKLOAD}/manifest.json"
  printf '{}\n' >"${WORKLOAD}/binding.json"
  printf 'provides\n' >"${WORKLOAD}/provides.json"
  printf 'requires\n' >"${WORKLOAD}/requires.json"
  printf 'unit\n' >"${WORKLOAD}/systemd/app.container"
  printf 'secret\n' >"${WORKLOAD}/persist/data.txt"
}

# --- happy path: zip contents + staging ---
setup_internal_workload
ZIP_ONLY="${TMP}/only.zip"
artifact_prep_internal_zip "${WORKLOAD}" "${ZIP_ONLY}" \
  || fail "artifact_prep_internal_zip must succeed"
[[ -f "${ZIP_ONLY}" ]] || fail "zip output must exist"

members="$(zip_members "${ZIP_ONLY}")"
echo "${members}" | grep -Fxq 'provides.json' \
  || fail "zip must include provides.json"
echo "${members}" | grep -Fxq 'requires.json' \
  || fail "zip must include requires.json"
echo "${members}" | grep -Fxq 'systemd/app.container' \
  || fail "zip must include systemd/"
if echo "${members}" | grep -Fq 'manifest.json'; then
  fail "zip must exclude manifest.json"
fi
if echo "${members}" | grep -Fq 'binding.json'; then
  fail "zip must exclude binding.json"
fi
if echo "${members}" | grep -Fq 'persist/'; then
  fail "zip must exclude persist/"
fi
pass "artifact_prep_internal_zip happy path contents"

sha="$(artifact_prep_internal "${WORKLOAD}")" \
  || fail "artifact_prep_internal must succeed"
[[ "${sha}" =~ ^[0-9a-f]{64}$ ]] || fail "prep must print lowercase sha256"
[[ -f "${ENV_ROOT}/.artifact-cache/analytics.staging" ]] \
  || fail "staging record must exist"
staging_body="$(tr -d '\n' <"${ENV_ROOT}/.artifact-cache/analytics.staging")"
[[ "${staging_body}" == "${sha}" ]] || fail "staging must match printed sha256"
[[ -f "${ENV_ROOT}/.artifact-cache/analytics-${sha}.zip" ]] \
  || fail "content-addressed cache zip must exist"
got="$(artifact_staging_read "${ENV_ROOT}" analytics)" \
  || fail "artifact_staging_read must succeed after prep"
expected_zip="$(python3 - "${ENV_ROOT}" analytics "${sha}" <<'PY'
import sys
from pathlib import Path

env = Path(sys.argv[1]).resolve()
basename = sys.argv[2]
sha = sys.argv[3]
print(str((env / ".artifact-cache" / f"{basename}-{sha}.zip").resolve()))
PY
)"
[[ "${got}" == "${expected_zip}" ]] \
  || fail "read must return staged zip path (got=${got} expected=${expected_zip})"
pass "artifact_prep_internal happy path staging"

# --- manifest source unchanged ---
source_before="$(artifact_source_from_manifest "${WORKLOAD}/manifest.json")"
source_after="$(artifact_source_from_manifest "${WORKLOAD}/manifest.json")"
[[ "${source_after}" == "${source_before}" && "${source_before}" == '{"kind":"internal"}' ]] \
  || fail "manifest source must remain internal after prep"
pass "manifest source unchanged"

# --- persist/ excluded even when only persist differs ---
rm -rf "${WORKLOAD}"
setup_internal_workload
ZIP_PERSIST="${TMP}/persist.zip"
artifact_prep_internal_zip "${WORKLOAD}" "${ZIP_PERSIST}" \
  || fail "zip with persist/ must succeed"
if member_has "${ZIP_PERSIST}" 'persist/data.txt' 2>/dev/null; then
  fail "persist/data.txt must not appear in zip"
fi
pass "persist/ excluded"

# --- non-internal source fails closed ---
rm -rf "${WORKLOAD}"
mkdir -p "${WORKLOAD}"
printf '{"intent":"run","source":{"kind":"zip","path":"artifact.zip"}}\n' >"${WORKLOAD}/manifest.json"
if artifact_prep_internal "${WORKLOAD}" >/dev/null 2>&1; then
  fail "non-internal source must fail closed"
fi
pass "non-internal source fails closed"

# --- missing manifest fails closed ---
rm -rf "${WORKLOAD}"
mkdir -p "${WORKLOAD}"
if artifact_prep_internal "${WORKLOAD}" >/dev/null 2>&1; then
  fail "missing manifest must fail closed"
fi
pass "missing manifest fails closed"

# --- invalid manifest fails closed ---
printf '{"intent":"run","source":{"kind":"Internal"}}\n' >"${WORKLOAD}/manifest.json"
if artifact_prep_internal "${WORKLOAD}" >/dev/null 2>&1; then
  fail "invalid manifest source must fail closed"
fi
pass "invalid manifest fails closed"

# --- build.json: stub podman creates output before zip ---
rm -rf "${WORKLOAD}"
setup_internal_workload
cat >"${WORKLOAD}/build.json" <<'EOF'
{
  "image": "docker.io/library/alpine:3.20",
  "command": "make www",
  "output": "www"
}
EOF

BIN="${TMP}/bin"
mkdir -p "${BIN}"
RECORD="${TMP}/podman-args.txt"
export ARTIFACT_BUILD_TEST_RECORD="${RECORD}"
export ARTIFACT_BUILD_TEST_MATERIALS="${WORKLOAD}"

cat >"${BIN}/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: >"${ARTIFACT_BUILD_TEST_RECORD}"
workdir=""
i=0
args=("$@")
while [[ $i -lt ${#args[@]} ]]; do
  printf '%s\n' "${args[$i]}" >>"${ARTIFACT_BUILD_TEST_RECORD}"
  if [[ "${args[$i]}" == "-w" ]]; then
    i=$((i + 1))
    workdir="${args[$i]}"
    printf '%s\n' "${args[$i]}" >>"${ARTIFACT_BUILD_TEST_RECORD}"
  fi
  i=$((i + 1))
done
host_root="${ARTIFACT_BUILD_TEST_MATERIALS}"
if [[ "${workdir}" == /materials ]]; then
  host_cwd="${host_root}"
elif [[ "${workdir}" == /materials/* ]]; then
  host_cwd="${host_root}/${workdir#/materials/}"
else
  echo "stub podman: unexpected -w ${workdir}" >&2
  exit 1
fi
mkdir -p "${host_cwd}"
printf 'built\n' >"${host_cwd}/www"
EOF
chmod +x "${BIN}/podman"
export PATH="${BIN}:${PATH}"

BUILD_ZIP="${TMP}/build.zip"
artifact_prep_internal_zip "${WORKLOAD}" "${BUILD_ZIP}" \
  || fail "prep zip with build.json must succeed"
member_has "${BUILD_ZIP}" 'www' \
  || fail "build output www must be included in zip"
grep -Fxq -- '/materials' "${RECORD}" \
  || fail "build must use /materials workdir for internal Artifact root"
pass "build.json runs Artifact Build before zip"

# --- zip path Source: extract → re-zip → staging ---
ZIP_WL="${ENV_ROOT}/zip-path"
mkdir -p "${ZIP_WL}"
printf '{}\n' >"${ZIP_WL}/binding.json"
cat >"${ZIP_WL}/manifest.json" <<'EOF'
{ "intent": "run", "source": {"kind":"zip","path":"artifact.zip"} }
EOF
ARTIFACT_SRC="${TMP}/zip-artifact-src"
mkdir -p "${ARTIFACT_SRC}/www"
printf '{ "directories": { "www": "static" } }\n' >"${ARTIFACT_SRC}/provides.json"
printf '{ "database": false, "cache": false }\n' >"${ARTIFACT_SRC}/requires.json"
printf 'from-zip\n' >"${ARTIFACT_SRC}/www/index.html"
(cd "${ARTIFACT_SRC}" && zip -qr "${ZIP_WL}/artifact.zip" .)

zip_source_before="$(artifact_source_from_manifest "${ZIP_WL}/manifest.json")"
sha_zip="$(artifact_prep_workload "${ZIP_WL}")" \
  || fail "zip path prep must succeed"
[[ "${sha_zip}" =~ ^[0-9a-f]{64}$ ]] || fail "zip path prep must print sha256"
[[ -f "${ENV_ROOT}/.artifact-cache/zip-path-${sha_zip}.zip" ]] \
  || fail "zip path cache zip must exist"
members="$(zip_members "${ENV_ROOT}/.artifact-cache/zip-path-${sha_zip}.zip")"
echo "${members}" | grep -Fxq 'provides.json' \
  || fail "normalized zip path artifact must include provides.json at root"
echo "${members}" | grep -Fxq 'www/index.html' \
  || fail "normalized zip path artifact must include www/"
zip_source_after="$(artifact_source_from_manifest "${ZIP_WL}/manifest.json")"
[[ "${zip_source_after}" == "${zip_source_before}" ]] \
  || fail "zip path manifest source must be unchanged after prep"
pass "zip path Source prep"

# --- zip URI Source: stub curl fetch → re-zip ---
URI_WL="${ENV_ROOT}/zip-uri"
mkdir -p "${URI_WL}"
printf '{}\n' >"${URI_WL}/binding.json"
cat >"${URI_WL}/manifest.json" <<'EOF'
{ "intent": "run", "source": {"kind":"zip","uri":"http://127.0.0.1:9/remote.zip"} }
EOF
URI_ARTIFACT_SRC="${TMP}/uri-artifact-src"
mkdir -p "${URI_ARTIFACT_SRC}"
printf '{}\n' >"${URI_ARTIFACT_SRC}/provides.json"
printf '{ "database": false, "cache": false }\n' >"${URI_ARTIFACT_SRC}/requires.json"
URI_FETCH_ZIP="${TMP}/uri-fetch.zip"
(cd "${URI_ARTIFACT_SRC}" && zip -qr "${URI_FETCH_ZIP}" .)

CURL_BIN="${TMP}/curl-bin"
mkdir -p "${CURL_BIN}"
export ARTIFACT_PREP_TEST_ZIP="${URI_FETCH_ZIP}"
cat >"${CURL_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  if [[ "${args[$i]}" == "-o" ]]; then
    i=$((i + 1))
    out="${args[$i]}"
  fi
  i=$((i + 1))
done
[[ -n "${out}" && -f "${ARTIFACT_PREP_TEST_ZIP:-}" ]] || exit 1
cp "${ARTIFACT_PREP_TEST_ZIP}" "${out}"
EOF
chmod +x "${CURL_BIN}/curl"

uri_source_before="$(artifact_source_from_manifest "${URI_WL}/manifest.json")"
sha_uri="$(
  PATH="${CURL_BIN}:${BIN}:${PATH}" artifact_prep_workload "${URI_WL}"
)" || fail "zip URI prep must succeed"
members="$(zip_members "${ENV_ROOT}/.artifact-cache/zip-uri-${sha_uri}.zip")"
echo "${members}" | grep -Fxq 'provides.json' \
  || fail "normalized zip URI artifact must include provides.json at root"
uri_source_after="$(artifact_source_from_manifest "${URI_WL}/manifest.json")"
[[ "${uri_source_after}" == "${uri_source_before}" ]] \
  || fail "zip URI manifest source must be unchanged after prep"
pass "zip URI Source prep"

# --- git Source: stub git obtain → zip Artifact path ---
GIT_WL="${ENV_ROOT}/git-wl"
GIT_STUBS="${TMP}/git-stubs"
mkdir -p "${GIT_WL}" "${GIT_STUBS}"
printf '{}\n' >"${GIT_WL}/binding.json"
cat >"${GIT_WL}/manifest.json" <<'EOF'
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
    init|remote|fetch) cmd="$a"; break ;;
    checkout) cmd="$a"; break ;;
  esac
done
case "${cmd}" in
  init|remote|fetch) exit 0 ;;
  checkout)
    [[ -n "${materials}" ]] || exit 1
    mkdir -p "${materials}/app/www"
    printf '{ "directories": { "www": "static" } }\n' \
      >"${materials}/app/provides.json"
    printf '{ "database": false, "cache": false }\n' \
      >"${materials}/app/requires.json"
    printf 'from-git\n' >"${materials}/app/www/index.html"
    exit 0
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${GIT_STUBS}/git"

git_source_before="$(artifact_source_from_manifest "${GIT_WL}/manifest.json")"
sha_git="$(
  PATH="${GIT_STUBS}:${BIN}:${PATH}" artifact_prep_workload "${GIT_WL}"
)" || fail "git Source prep must succeed"
members="$(zip_members "${ENV_ROOT}/.artifact-cache/git-wl-${sha_git}.zip")"
echo "${members}" | grep -Fxq 'provides.json' \
  || fail "git prep zip must include provides.json at Artifact root"
echo "${members}" | grep -Fxq 'www/index.html' \
  || fail "git prep zip must include www/index.html"
git_source_after="$(artifact_source_from_manifest "${GIT_WL}/manifest.json")"
[[ "${git_source_after}" == "${git_source_before}" ]] \
  || fail "git manifest source must be unchanged after prep"
pass "git Source prep"

# --- local Source: Projects root stage → zip Artifact path ---
PROJ="${TMP}/projects"
LOCAL_WL="${ENV_ROOT}/local-wl"
mkdir -p "${PROJ}/repo/pkg/app" "${PROJ}/repo/in-repo-sibling" "${LOCAL_WL}"
git -C "${PROJ}/repo" init -q
git -C "${PROJ}/repo" config user.email "prep@test"
git -C "${PROJ}/repo" config user.name "prep"
printf 'artifact\n' >"${PROJ}/repo/pkg/app/file"
printf 'sibling\n' >"${PROJ}/repo/in-repo-sibling/x"
git -C "${PROJ}/repo" add .
git -C "${PROJ}/repo" commit -qm "init"
printf '{}\n' >"${LOCAL_WL}/binding.json"
cat >"${LOCAL_WL}/manifest.json" <<'EOF'
{ "intent": "run", "source": { "kind": "local", "path": "repo/pkg/app" } }
EOF
printf '{ "directories": { "www": "static" } }\n' \
  >"${PROJ}/repo/pkg/app/provides.json"
printf '{ "database": false, "cache": false }\n' \
  >"${PROJ}/repo/pkg/app/requires.json"
mkdir -p "${PROJ}/repo/pkg/app/www"
printf 'from-local\n' >"${PROJ}/repo/pkg/app/www/index.html"

local_source_before="$(artifact_source_from_manifest "${LOCAL_WL}/manifest.json")"
sha_local="$(
  PROPRAETOR_PROJECTS_ROOT="${PROJ}" PATH="${BIN}:${PATH}" \
    artifact_prep_workload "${LOCAL_WL}"
)" || fail "local Source prep must succeed"
members="$(zip_members "${ENV_ROOT}/.artifact-cache/local-wl-${sha_local}.zip")"
echo "${members}" | grep -Fxq 'provides.json' \
  || fail "local prep zip must include provides.json at Artifact root"
echo "${members}" | grep -Fxq 'www/index.html' \
  || fail "local prep zip must include www/index.html"
local_source_after="$(artifact_source_from_manifest "${LOCAL_WL}/manifest.json")"
[[ "${local_source_after}" == "${local_source_before}" ]] \
  || fail "local operator manifest source must stay Projects-root-relative after prep"
pass "local Source prep"

# --- fail closed: local without Projects root ---
if PROPRAETOR_PROJECTS_ROOT='' PATH="${BIN}:${PATH}" \
  artifact_prep_workload "${LOCAL_WL}" >/dev/null 2>&1; then
  fail "local prep must fail closed when PROPRAETOR_PROJECTS_ROOT unset"
fi
pass "local prep fails closed without Projects root"

# --- fail closed: non-internal Environment tree with provides.json ---
INLINE_WL="${ENV_ROOT}/inline-wl"
mkdir -p "${INLINE_WL}"
printf '{}\n' >"${INLINE_WL}/binding.json"
cat >"${INLINE_WL}/manifest.json" <<'EOF'
{ "intent": "run", "source": {"kind":"zip","path":"artifact.zip"} }
EOF
printf '{}\n' >"${INLINE_WL}/provides.json"
if artifact_prep_workload "${INLINE_WL}" >/dev/null 2>&1; then
  fail "non-internal Environment provides.json must fail closed at prep"
fi
pass "non-internal Environment inline contracts fail closed"

# --- fail closed: reserved Artifact Build output in zip prep ---
BUILD_ZIP_WL="${ENV_ROOT}/build-zip-wl"
mkdir -p "${BUILD_ZIP_WL}"
printf '{}\n' >"${BUILD_ZIP_WL}/binding.json"
cat >"${BUILD_ZIP_WL}/manifest.json" <<'EOF'
{ "intent": "run", "source": {"kind":"zip","path":"artifact.zip"} }
EOF
BUILD_ARTIFACT_SRC="${TMP}/build-artifact-src"
mkdir -p "${BUILD_ARTIFACT_SRC}"
printf '{}\n' >"${BUILD_ARTIFACT_SRC}/provides.json"
printf '{ "database": false, "cache": false }\n' >"${BUILD_ARTIFACT_SRC}/requires.json"
cat >"${BUILD_ARTIFACT_SRC}/build.json" <<'EOF'
{
  "image": "docker.io/library/alpine:3.20",
  "command": "make bad",
  "output": "provides.json"
}
EOF
(cd "${BUILD_ARTIFACT_SRC}" && zip -qr "${BUILD_ZIP_WL}/artifact.zip" .)
if PATH="${BIN}:${PATH}" artifact_prep_workload "${BUILD_ZIP_WL}" >/dev/null 2>&1; then
  fail "zip prep must fail closed on reserved build output path"
fi
pass "zip prep fails closed on reserved build output"

echo "All Artifact Prep unit tests passed."
