#!/usr/bin/env bash
# Unit tests: Workload Source parse/validate (ADR-0053 / #199).
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

# --- internal ---
[[ "$(artifact_source_validate internal)" == "internal" ]] \
  || fail "internal Source must validate"
pass "internal Source"

# --- zip URI (unauthenticated http(s), including loopback) ---
zip_uri='https://github.com/example/repo/archive/refs/tags/v1.0.0.zip'
[[ "$(artifact_source_validate "${zip_uri}")" == "${zip_uri}" ]] \
  || fail "https zip URI must validate"
http_uri='http://cdn.example.com/artifacts/app.zip'
[[ "$(artifact_source_validate "${http_uri}")" == "${http_uri}" ]] \
  || fail "http zip URI must validate"
loopback_uri='http://127.0.0.1:9/artifact.ZIP'
[[ "$(artifact_source_validate "${loopback_uri}")" == "${loopback_uri}" ]] \
  || fail "loopback zip URI with case-folded suffix must validate"
pass "zip URI Source"

# --- relative zip path ---
[[ "$(artifact_source_validate 'artifact.zip')" == "artifact.zip" ]] \
  || fail "basename zip path must validate"
[[ "$(artifact_source_validate 'vendor/app.zip')" == "vendor/app.zip" ]] \
  || fail "nested zip path must validate"
[[ "$(artifact_source_validate 'vendor/App.ZIP')" == "vendor/App.ZIP" ]] \
  || fail "nested zip path with case-folded suffix must validate"
pass "relative zip path Source"

# --- fail closed ---
if artifact_source_validate '' >/dev/null 2>&1; then
  fail "empty Source must fail closed"
fi
if artifact_source_validate 'git' >/dev/null 2>&1; then
  fail "non-zip Source must fail closed"
fi
if artifact_source_validate 'https://example.com/app.tar.gz' >/dev/null 2>&1; then
  fail "non-zip URI must fail closed"
fi
if artifact_source_validate 'ftp://example.com/app.zip' >/dev/null 2>&1; then
  fail "non-http(s) URI must fail closed"
fi
if artifact_source_validate 'file:///tmp/app.zip' >/dev/null 2>&1; then
  fail "file:// Source must fail closed"
fi
if artifact_source_validate 'Internal' >/dev/null 2>&1; then
  fail "Source internal is case-sensitive"
fi
if artifact_source_validate './artifact.zip' >/dev/null 2>&1; then
  fail "./ zip path must fail closed"
fi
if artifact_source_validate '../artifact.zip' >/dev/null 2>&1; then
  fail ".. zip path must fail closed"
fi
if artifact_source_validate '/tmp/artifact.zip' >/dev/null 2>&1; then
  fail "absolute zip path must fail closed"
fi
if artifact_source_validate 'vendor/./app.zip' >/dev/null 2>&1; then
  fail "dot-segment zip path must fail closed"
fi
if artifact_source_validate '.zip' >/dev/null 2>&1; then
  fail "empty-basename .zip must fail closed"
fi
pass "invalid Source fails closed"

# --- from Manifest ---
cat >"${TMP}/manifest.json" <<EOF
{ "intent": "run", "source": "internal" }
EOF
[[ "$(artifact_source_from_manifest "${TMP}/manifest.json")" == "internal" ]] \
  || fail "Manifest source=internal"
cat >"${TMP}/manifest.json" <<EOF
{ "intent": "run", "source": "${zip_uri}" }
EOF
[[ "$(artifact_source_from_manifest "${TMP}/manifest.json")" == "${zip_uri}" ]] \
  || fail "Manifest source=zip URI"
cat >"${TMP}/manifest.json" <<'EOF'
{ "intent": "run", "source": "vendor/app.zip" }
EOF
[[ "$(artifact_source_from_manifest "${TMP}/manifest.json")" == "vendor/app.zip" ]] \
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

[[ "$(artifact_source_kind internal)" == "internal" ]] \
  || fail "kind internal"
[[ "$(artifact_source_kind "${zip_uri}")" == "uri" ]] \
  || fail "kind uri"
[[ "$(artifact_source_kind artifact.zip)" == "path" ]] \
  || fail "kind path"
[[ "$(artifact_source_kind vendor/app.zip)" == "path" ]] \
  || fail "kind nested path"
pass "artifact_source_kind"

# --- Environment tree vs Source: zip must not carry Artifact contracts ---
ZIP_TREE="${TMP}/zip-wl"
mkdir -p "${ZIP_TREE}"
cat >"${ZIP_TREE}/manifest.json" <<EOF
{ "intent": "run", "source": "${zip_uri}" }
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

PATH_TREE="${TMP}/path-wl"
mkdir -p "${PATH_TREE}/vendor"
cat >"${PATH_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": "vendor/app.zip" }
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
{ "intent": "run", "source": "internal" }
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
{ "intent": "run", "source": "vendor/link.zip" }
EOF
if artifact_source_tree_gate "${PATH_TREE}" >/dev/null 2>&1; then
  fail "symlink path zip must fail tree gate"
fi
rm -f "${PATH_TREE}/vendor/link.zip"
cat >"${PATH_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": "vendor/app.zip" }
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
