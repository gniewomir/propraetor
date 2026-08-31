#!/usr/bin/env bash
# Unit tests: Workload Source parse/validate (ADR-0060 / ADR-0053).
# Seam: artifact_source_validate / artifact_source_kind /
# artifact_source_from_manifest / artifact_source_environment_tree_gate /
# artifact_source_tree_gate / artifact_source_zip_extract.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=source.sh
source "${REPO_ROOT}/internals/lib/artifact/source.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/artifact-source.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

INTERNAL_SRC='{"kind":"internal"}'
zip_uri='https://github.com/example/repo/archive/refs/tags/v1.0.0.zip'
ZIP_URI_SRC="{\"kind\":\"zip\",\"uri\":\"${zip_uri}\"}"
http_uri='http://cdn.example.com/artifacts/app.zip'
HTTP_URI_SRC="{\"kind\":\"zip\",\"uri\":\"${http_uri}\"}"
loopback_uri='http://127.0.0.1:9/artifact.ZIP'
LOOPBACK_URI_SRC="{\"kind\":\"zip\",\"uri\":\"${loopback_uri}\"}"
ZIP_PATH_SRC='{"kind":"zip","path":"artifact.zip"}'
ZIP_NESTED_SRC='{"kind":"zip","path":"vendor/app.zip"}'
ZIP_CASE_SRC='{"kind":"zip","path":"vendor/App.ZIP"}'

# --- internal ---
[[ "$(artifact_source_validate "${INTERNAL_SRC}")" == "${INTERNAL_SRC}" ]] \
  || fail "internal Source must validate"
pass "internal Source"

# --- zip URI (unauthenticated http(s), including loopback) ---
[[ "$(artifact_source_validate "${ZIP_URI_SRC}")" == "${ZIP_URI_SRC}" ]] \
  || fail "https zip URI must validate"
[[ "$(artifact_source_validate "${HTTP_URI_SRC}")" == "${HTTP_URI_SRC}" ]] \
  || fail "http zip URI must validate"
[[ "$(artifact_source_validate "${LOOPBACK_URI_SRC}")" == "${LOOPBACK_URI_SRC}" ]] \
  || fail "loopback zip URI with case-folded suffix must validate"
pass "zip URI Source"

# --- relative zip path ---
[[ "$(artifact_source_validate "${ZIP_PATH_SRC}")" == "${ZIP_PATH_SRC}" ]] \
  || fail "basename zip path must validate"
[[ "$(artifact_source_validate "${ZIP_NESTED_SRC}")" == "${ZIP_NESTED_SRC}" ]] \
  || fail "nested zip path must validate"
[[ "$(artifact_source_validate "${ZIP_CASE_SRC}")" == "${ZIP_CASE_SRC}" ]] \
  || fail "nested zip path with case-folded suffix must validate"
pass "relative zip path Source"

# --- fail closed ---
if artifact_source_validate '' >/dev/null 2>&1; then
  fail "empty Source must fail closed"
fi
if artifact_source_validate 'internal' >/dev/null 2>&1; then
  fail "string internal Source must fail closed"
fi
if artifact_source_validate 'artifact.zip' >/dev/null 2>&1; then
  fail "string zip path Source must fail closed"
fi
if artifact_source_validate '{"kind":"zip","uri":"https://example.com/app.tar.gz"}' >/dev/null 2>&1; then
  fail "non-zip URI must fail closed"
fi
if artifact_source_validate '{"kind":"zip","uri":"ftp://example.com/app.zip"}' >/dev/null 2>&1; then
  fail "non-http(s) URI must fail closed"
fi
if artifact_source_validate '{"kind":"zip","uri":"file:///tmp/app.zip"}' >/dev/null 2>&1; then
  fail "file:// Source must fail closed"
fi
if artifact_source_validate '{"kind":"Internal"}' >/dev/null 2>&1; then
  fail "Source internal kind is case-sensitive"
fi
if artifact_source_validate '{"kind":"zip","path":"./artifact.zip"}' >/dev/null 2>&1; then
  fail "./ zip path must fail closed"
fi
if artifact_source_validate '{"kind":"zip","path":"../artifact.zip"}' >/dev/null 2>&1; then
  fail ".. zip path must fail closed"
fi
if artifact_source_validate '{"kind":"zip","path":"/tmp/artifact.zip"}' >/dev/null 2>&1; then
  fail "absolute zip path must fail closed"
fi
if artifact_source_validate '{"kind":"zip","path":"vendor/./app.zip"}' >/dev/null 2>&1; then
  fail "dot-segment zip path must fail closed"
fi
if artifact_source_validate '{"kind":"zip","path":".zip"}' >/dev/null 2>&1; then
  fail "empty-basename .zip must fail closed"
fi
if artifact_source_validate '{"kind":"zip","path":"vendor/app.zip","uri":"https://x/a.zip"}' >/dev/null 2>&1; then
  fail "zip Source with both path and uri must fail closed"
fi
pass "invalid Source fails closed"

# --- from Manifest ---
cat >"${TMP}/manifest.json" <<EOF
{ "intent": "run", "source": { "kind": "internal" } }
EOF
[[ "$(artifact_source_from_manifest "${TMP}/manifest.json")" == "${INTERNAL_SRC}" ]] \
  || fail "Manifest source=internal"
cat >"${TMP}/manifest.json" <<EOF
{ "intent": "run", "source": { "kind": "zip", "uri": "${zip_uri}" } }
EOF
[[ "$(artifact_source_from_manifest "${TMP}/manifest.json")" == "${ZIP_URI_SRC}" ]] \
  || fail "Manifest source=zip URI"
cat >"${TMP}/manifest.json" <<'EOF'
{ "intent": "run", "source": { "kind": "zip", "path": "vendor/app.zip" } }
EOF
[[ "$(artifact_source_from_manifest "${TMP}/manifest.json")" == "${ZIP_NESTED_SRC}" ]] \
  || fail "Manifest source=zip path"
cat >"${TMP}/manifest.json" <<'EOF'
{ "intent": "run" }
EOF
if artifact_source_from_manifest "${TMP}/manifest.json" >/dev/null 2>&1; then
  fail "missing Manifest source must fail closed"
fi
cat >"${TMP}/manifest.json" <<'EOF'
{ "intent": "run", "source": "oci://x" }
EOF
if artifact_source_from_manifest "${TMP}/manifest.json" >/dev/null 2>&1; then
  fail "invalid Manifest source must fail closed"
fi
pass "artifact_source_from_manifest"

[[ "$(artifact_source_kind "${INTERNAL_SRC}")" == "internal" ]] \
  || fail "kind internal"
[[ "$(artifact_source_kind "${ZIP_URI_SRC}")" == "zip" ]] \
  || fail "kind zip uri"
[[ "$(artifact_source_kind "${ZIP_PATH_SRC}")" == "zip" ]] \
  || fail "kind zip path"
[[ "$(artifact_source_kind "${ZIP_NESTED_SRC}")" == "zip" ]] \
  || fail "kind zip nested path"
[[ "$(artifact_source_zip_uri "${ZIP_URI_SRC}")" == "${zip_uri}" ]] \
  || fail "zip uri field"
[[ "$(artifact_source_zip_path "${ZIP_NESTED_SRC}")" == "vendor/app.zip" ]] \
  || fail "zip path field"
pass "artifact_source_kind"

# --- git / local object Source (ADR-0058) ---
GIT_SRC='{"commit":"0123456789abcdef0123456789abcdef01234567","kind":"git","path":"packages/app","url":"https://example.com/repo.git"}'
cat >"${TMP}/manifest.json" <<EOF
{ "intent": "run", "source": {
  "kind": "git",
  "url": "https://example.com/repo.git",
  "commit": "0123456789abcdef0123456789abcdef01234567",
  "path": "packages/app"
}}
EOF
[[ "$(artifact_source_from_manifest "${TMP}/manifest.json")" == "${GIT_SRC}" ]] \
  || fail "Manifest git Source must canonicalize"
[[ "$(artifact_source_kind "${GIT_SRC}")" == "git" ]] \
  || fail "kind git"
[[ "$(artifact_source_git_url "${GIT_SRC}")" == "https://example.com/repo.git" ]] \
  || fail "git url field"
[[ "$(artifact_source_git_commit "${GIT_SRC}")" == "0123456789abcdef0123456789abcdef01234567" ]] \
  || fail "git commit field"
[[ "$(artifact_source_artifact_path "${GIT_SRC}")" == "packages/app" ]] \
  || fail "git path field"
pass "git Source"

LOCAL_SRC='{"kind":"local","path":"tyrant/prototype/inbox"}'
cat >"${TMP}/manifest.json" <<EOF
{ "intent": "run", "source": { "kind": "local", "path": "tyrant/prototype/inbox" } }
EOF
[[ "$(artifact_source_from_manifest "${TMP}/manifest.json")" == "${LOCAL_SRC}" ]] \
  || fail "Manifest local Source must canonicalize"
[[ "$(artifact_source_kind "${LOCAL_SRC}")" == "local" ]] \
  || fail "kind local"
[[ "$(artifact_source_artifact_path "${LOCAL_SRC}")" == "tyrant/prototype/inbox" ]] \
  || fail "local path field"
pass "local Source"

# git / local fail closed
cat >"${TMP}/manifest.json" <<'EOF'
{ "intent": "run", "source": { "kind": "git", "url": "git@github.com:x/y.git", "commit": "0123456789abcdef0123456789abcdef01234567", "path": "." } }
EOF
if artifact_source_from_manifest "${TMP}/manifest.json" >/dev/null 2>&1; then
  fail "SSH git URL must fail closed"
fi
cat >"${TMP}/manifest.json" <<'EOF'
{ "intent": "run", "source": { "kind": "git", "url": "https://example.com/r.git", "commit": "abc", "path": "." } }
EOF
if artifact_source_from_manifest "${TMP}/manifest.json" >/dev/null 2>&1; then
  fail "short git commit must fail closed"
fi
cat >"${TMP}/manifest.json" <<'EOF'
{ "intent": "run", "source": {
  "kind": "git",
  "url": "https://example.com/repo.git",
  "commit": "0123456789ABCDEF0123456789ABCDEF01234567",
  "path": "."
}}
EOF
[[ "$(artifact_source_git_commit "$(artifact_source_from_manifest "${TMP}/manifest.json")")" == "0123456789abcdef0123456789abcdef01234567" ]] \
  || fail "uppercase git commit must canonicalize to lowercase"
cat >"${TMP}/manifest.json" <<'EOF'
{ "intent": "run", "source": { "kind": "local", "path": "../escape" } }
EOF
if artifact_source_from_manifest "${TMP}/manifest.json" >/dev/null 2>&1; then
  fail "local path with .. must fail closed"
fi
cat >"${TMP}/manifest.json" <<'EOF'
{ "intent": "run", "source": { "kind": "local", "path": "/abs" } }
EOF
if artifact_source_from_manifest "${TMP}/manifest.json" >/dev/null 2>&1; then
  fail "absolute local path must fail closed"
fi
cat >"${TMP}/manifest.json" <<'EOF'
{ "intent": "run", "source": { "kind": "local", "path": "." } }
EOF
[[ "$(artifact_source_artifact_path "$(artifact_source_from_manifest "${TMP}/manifest.json")")" == "." ]] \
  || fail "local path . must be allowed"
pass "git/local Source fail closed"

# --- Environment tree vs Source: zip must not carry Artifact contracts ---
ZIP_TREE="${TMP}/zip-wl"
mkdir -p "${ZIP_TREE}"
cat >"${ZIP_TREE}/manifest.json" <<EOF
{ "intent": "run", "source": { "kind": "zip", "uri": "${zip_uri}" } }
EOF
printf '{}\n' >"${ZIP_TREE}/binding.json"
artifact_source_environment_tree_gate "${ZIP_TREE}" \
  || fail "zip Environment Manifest+Binding must pass"
printf '{ "database": false, "cache": false }\n' >"${ZIP_TREE}/requires.json"
if artifact_source_environment_tree_gate "${ZIP_TREE}" >/dev/null 2>&1; then
  fail "zip Environment requires.json must fail closed"
fi
rm -f "${ZIP_TREE}/requires.json"
printf '{}\n' >"${ZIP_TREE}/provides.json"
if artifact_source_environment_tree_gate "${ZIP_TREE}" >/dev/null 2>&1; then
  fail "zip Environment provides.json must fail closed"
fi
rm -f "${ZIP_TREE}/provides.json"
pass "zip Environment Artifact contracts fail closed"

GIT_TREE="${TMP}/git-wl"
mkdir -p "${GIT_TREE}"
cat >"${GIT_TREE}/manifest.json" <<EOF
{ "intent": "run", "source": {
  "kind": "git",
  "url": "https://example.com/repo.git",
  "commit": "0123456789abcdef0123456789abcdef01234567",
  "path": "."
}}
EOF
printf '{}\n' >"${GIT_TREE}/binding.json"
artifact_source_environment_tree_gate "${GIT_TREE}" \
  || fail "git Environment Manifest+Binding must pass"
printf '{}\n' >"${GIT_TREE}/provides.json"
if artifact_source_environment_tree_gate "${GIT_TREE}" >/dev/null 2>&1; then
  fail "git Environment provides.json must fail closed"
fi
rm -f "${GIT_TREE}/provides.json"
pass "git Environment Artifact contracts fail closed"

LOCAL_TREE="${TMP}/local-wl"
mkdir -p "${LOCAL_TREE}"
cat >"${LOCAL_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": { "kind": "local", "path": "pkg/app" } }
EOF
printf '{}\n' >"${LOCAL_TREE}/binding.json"
artifact_source_environment_tree_gate "${LOCAL_TREE}" \
  || fail "local Environment Manifest+Binding must pass"
printf '{}\n' >"${LOCAL_TREE}/provides.json"
if artifact_source_environment_tree_gate "${LOCAL_TREE}" >/dev/null 2>&1; then
  fail "local Environment provides.json must fail closed"
fi
rm -f "${LOCAL_TREE}/provides.json"
pass "local Environment Artifact contracts fail closed"

# --- resolve Artifact path under materials (escape gate) ---
MAT="${TMP}/materials"
mkdir -p "${MAT}/pkg/app"
printf 'ok\n' >"${MAT}/pkg/app/marker"
got="$(artifact_source_resolve_artifact_root "${MAT}" "pkg/app")"
[[ -f "${got}/marker" ]] || fail "resolve Artifact root under materials"
got_dot="$(artifact_source_resolve_artifact_root "${MAT}" ".")"
[[ -d "${got_dot}/pkg/app" ]] || fail "resolve path . is materials root"
if artifact_source_resolve_artifact_root "${MAT}" "../escape" >/dev/null 2>&1; then
  fail "resolve must refuse .. escape"
fi
if artifact_source_resolve_artifact_root "${MAT}" "/abs" >/dev/null 2>&1; then
  fail "resolve must refuse absolute path"
fi
pass "artifact_source_resolve_artifact_root"

# --- local stage: Project root materials + staged Manifest path rewrite ---
PROJ="${TMP}/projects-root"
REPO="${PROJ}/repo"
mkdir -p "${REPO}/pkg/app" "${REPO}/in-repo-sibling" "${PROJ}/unrelated"
printf 'a\n' >"${REPO}/pkg/app/file"
printf 'in\n' >"${REPO}/in-repo-sibling/x"
printf 'out\n' >"${PROJ}/unrelated/y"
git -C "${REPO}" init --quiet
git -C "${REPO}" config user.email "test@example.com"
git -C "${REPO}" config user.name "test"
git -C "${REPO}" add .
git -C "${REPO}" commit --quiet -m init
STAGE_MAT="${TMP}/staged-materials"
STAGE_MANIFEST="${TMP}/staged-manifest.json"
cat >"${STAGE_MANIFEST}" <<'EOF'
{ "intent": "run", "source": { "kind": "local", "path": "repo/pkg/app" } }
EOF
# Operator SoT keeps Projects-root-relative path.
cat >"${LOCAL_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": { "kind": "local", "path": "repo/pkg/app" } }
EOF
PROPRAETOR_PROJECTS_ROOT="${PROJ}" artifact_source_stage_local_materials \
  "$(artifact_source_from_manifest "${LOCAL_TREE}/manifest.json")" \
  "${STAGE_MAT}" "${STAGE_MANIFEST}" \
  || fail "local stage must succeed"
[[ -f "${STAGE_MAT}/pkg/app/file" ]] || fail "stage must copy Artifact under Project root"
[[ -f "${STAGE_MAT}/in-repo-sibling/x" ]] || fail "stage must copy Project root siblings"
[[ ! -e "${STAGE_MAT}/unrelated" ]] || fail "stage must not copy Projects root outside Project root"
[[ ! -e "${STAGE_MAT}/repo" ]] || fail "stage materials are Project root contents, not Projects-root-shaped"
[[ "$(artifact_source_artifact_path "$(artifact_source_from_manifest "${STAGE_MANIFEST}")")" == "pkg/app" ]] \
  || fail "staged Manifest path must be Project-root-relative"
[[ "$(artifact_source_artifact_path "$(artifact_source_from_manifest "${LOCAL_TREE}/manifest.json")")" == "repo/pkg/app" ]] \
  || fail "operator SoT Manifest path must stay Projects-root-relative"
if PROPRAETOR_PROJECTS_ROOT="${PROJ}" artifact_source_stage_local_materials \
  '{"kind":"local","path":"missing/pkg"}' "${STAGE_MAT}-bad" "${STAGE_MANIFEST}" \
  >/dev/null 2>&1; then
  fail "local stage must fail when Artifact path missing"
fi
NO_GIT="${PROJ}/nogit/pkg"
mkdir -p "${NO_GIT}"
printf 'x\n' >"${NO_GIT}/file"
cat >"${STAGE_MANIFEST}.nogit" <<'EOF'
{ "intent": "run", "source": { "kind": "local", "path": "nogit/pkg" } }
EOF
if PROPRAETOR_PROJECTS_ROOT="${PROJ}" artifact_source_stage_local_materials \
  '{"kind":"local","path":"nogit/pkg"}' "${STAGE_MAT}-nogit" "${STAGE_MANIFEST}.nogit" \
  >/dev/null 2>&1; then
  fail "local stage must fail closed when Project root (git toplevel) missing"
fi
pass "artifact_source_stage_local_materials"

PATH_TREE="${TMP}/path-wl"
mkdir -p "${PATH_TREE}/vendor"
cat >"${PATH_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": { "kind": "zip", "path": "vendor/app.zip" } }
EOF
printf '{}\n' >"${PATH_TREE}/binding.json"
printf 'not-a-real-zip\n' >"${PATH_TREE}/vendor/app.zip"
artifact_source_environment_tree_gate "${PATH_TREE}" \
  || fail "path zip Environment Manifest+Binding must pass"
printf '{}\n' >"${PATH_TREE}/provides.json"
if artifact_source_environment_tree_gate "${PATH_TREE}" >/dev/null 2>&1; then
  fail "path zip Environment provides.json must fail closed"
fi
rm -f "${PATH_TREE}/provides.json"
pass "path zip Environment Artifact contracts fail closed"

INT_TREE="${TMP}/int-wl"
mkdir -p "${INT_TREE}"
cat >"${INT_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": { "kind": "internal" } }
EOF
printf '{}\n' >"${INT_TREE}/binding.json"
printf '{}\n' >"${INT_TREE}/provides.json"
printf '{ "database": false, "cache": false }\n' >"${INT_TREE}/requires.json"
artifact_source_environment_tree_gate "${INT_TREE}" \
  || fail "internal Environment Artifact contracts must pass"
pass "internal Environment Artifact contracts allowed"

# --- tree gate: path file + outbound symlink ---
artifact_source_tree_gate "${PATH_TREE}" \
  || fail "path zip regular file must pass tree gate"
rm -f "${PATH_TREE}/vendor/app.zip"
if artifact_source_tree_gate "${PATH_TREE}" >/dev/null 2>&1; then
  fail "missing path zip must fail tree gate"
fi
printf 'not-a-real-zip\n' >"${PATH_TREE}/vendor/app.zip"
ln -s app.zip "${PATH_TREE}/vendor/link.zip"
cat >"${PATH_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": { "kind": "zip", "path": "vendor/link.zip" } }
EOF
if artifact_source_tree_gate "${PATH_TREE}" >/dev/null 2>&1; then
  fail "symlink path zip must fail tree gate"
fi
rm -f "${PATH_TREE}/vendor/link.zip"
cat >"${PATH_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": { "kind": "zip", "path": "vendor/app.zip" } }
EOF
pass "path zip file gate"

ln -s "${TMP}/outside" "${INT_TREE}/escape"
if artifact_source_tree_gate "${INT_TREE}" >/dev/null 2>&1; then
  fail "outbound Workload symlink must fail tree gate"
fi
rm -f "${INT_TREE}/escape"
mkdir -p "${INT_TREE}/www"
printf 'in-tree\n' >"${INT_TREE}/www/index.html"
ln -s index.html "${INT_TREE}/www/home.html"
artifact_source_tree_gate "${INT_TREE}" \
  || fail "in-tree Workload symlink must pass tree gate"
ENV_LINK="${TMP}/env-link-wl"
ln -s "${INT_TREE}" "${ENV_LINK}"
artifact_source_tree_gate "${ENV_LINK}" \
  || fail "Environment-level Workload-dir symlink must pass tree gate"
pass "symlink gates"

# --- zip extract: slip + peel ---
EXTRACT_SRC="${TMP}/extract-src"
EXTRACT_DEST="${TMP}/extract-dest"
mkdir -p "${EXTRACT_SRC}/wrapper/www"
printf '{}\n' >"${EXTRACT_SRC}/wrapper/provides.json"
printf '{ "database": false, "cache": false }\n' >"${EXTRACT_SRC}/wrapper/requires.json"
printf 'from-wrapper\n' >"${EXTRACT_SRC}/wrapper/www/index.html"
(cd "${EXTRACT_SRC}" && zip -qr "${TMP}/wrapped.zip" wrapper)
rm -rf "${EXTRACT_DEST}"
artifact_source_zip_extract "${TMP}/wrapped.zip" "${EXTRACT_DEST}" \
  || fail "sole wrapper with Provides must peel"
[[ -f "${EXTRACT_DEST}/provides.json" ]] \
  || fail "peeled Artifact must expose provides.json at dest root"
[[ -f "${EXTRACT_DEST}/www/index.html" ]] \
  || fail "peeled Artifact must expose wrapper contents"
[[ ! -d "${EXTRACT_DEST}/wrapper" ]] \
  || fail "peel must not leave wrapper directory"
pass "zip extract peels sole wrapper with Provides"

mkdir -p "${EXTRACT_SRC}/flat"
printf '{}\n' >"${EXTRACT_SRC}/flat/provides.json"
printf '{ "database": false, "cache": false }\n' >"${EXTRACT_SRC}/flat/requires.json"
printf 'flat\n' >"${EXTRACT_SRC}/flat/readme.txt"
(cd "${EXTRACT_SRC}/flat" && zip -qr "${TMP}/flat.zip" .)
rm -rf "${EXTRACT_DEST}"
artifact_source_zip_extract "${TMP}/flat.zip" "${EXTRACT_DEST}" \
  || fail "zip-root Artifact must extract"
[[ -f "${EXTRACT_DEST}/provides.json" ]] \
  || fail "zip-root extract must keep provides.json at dest root"
[[ -f "${EXTRACT_DEST}/readme.txt" ]] \
  || fail "zip-root extract must keep members"
pass "zip extract without peel when Provides is at zip root"

mkdir -p "${EXTRACT_SRC}/junk/app"
printf '{}\n' >"${EXTRACT_SRC}/junk/app/provides.json"
printf 'x\n' >"${EXTRACT_SRC}/junk/__MACOSX"
(cd "${EXTRACT_SRC}/junk" && zip -qr "${TMP}/junk.zip" .)
rm -rf "${EXTRACT_DEST}"
artifact_source_zip_extract "${TMP}/junk.zip" "${EXTRACT_DEST}" \
  || fail "junk-beside-wrapper zip must extract"
[[ -f "${EXTRACT_DEST}/app/provides.json" ]] \
  || fail "strict peel must keep wrapper when archive root has extra entries"
[[ ! -f "${EXTRACT_DEST}/provides.json" ]] \
  || fail "strict peel must not promote wrapper when junk exists at archive root"
pass "zip extract does not peel when archive root has extra entries"

python3 - "${TMP}/slip.zip" <<'PY'
import zipfile, sys
with zipfile.ZipFile(sys.argv[1], "w") as zf:
    zf.writestr("../escape.txt", "nope")
    zf.writestr("provides.json", "{}\n")
PY
rm -rf "${EXTRACT_DEST}"
if artifact_source_zip_extract "${TMP}/slip.zip" "${EXTRACT_DEST}" >/dev/null 2>&1; then
  fail "zip-slip .. member must fail closed"
fi
pass "zip extract refuses .. members"

python3 - "${TMP}/absslip.zip" <<'PY'
import zipfile, sys
with zipfile.ZipFile(sys.argv[1], "w") as zf:
    zf.writestr("/tmp/escape.txt", "nope")
    zf.writestr("provides.json", "{}\n")
PY
rm -rf "${EXTRACT_DEST}"
if artifact_source_zip_extract "${TMP}/absslip.zip" "${EXTRACT_DEST}" >/dev/null 2>&1; then
  fail "absolute zip member must fail closed"
fi
pass "zip extract refuses absolute members"

# --- no dual-read of retired Manifest keys in Source helpers ---
if grep -E '\[.environment.\]|\[.database.\]|m\.get\("environment"\)|m\.get\("database"\)' \
    "${REPO_ROOT}/internals/lib/artifact/source.sh"; then
  fail "Source lib must not dual-read Manifest environment/database"
fi
pass "no Manifest environment/database dual-read"

echo "All artifact Source offline tests passed."
