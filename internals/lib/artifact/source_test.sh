#!/usr/bin/env bash
# Unit tests: Workload Source parse/validate (ADR-0053 / #199).
# Seam: artifact_source_validate / artifact_source_from_manifest /
# artifact_source_environment_tree_gate.
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

# --- public zip URI ---
zip_uri='https://github.com/example/repo/archive/refs/tags/v1.0.0.zip'
[[ "$(artifact_source_validate "${zip_uri}")" == "${zip_uri}" ]] \
  || fail "https zip URI must validate"
http_uri='http://cdn.example.com/artifacts/app.zip'
[[ "$(artifact_source_validate "${http_uri}")" == "${http_uri}" ]] \
  || fail "http zip URI must validate"
pass "public zip URI Source"

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
if artifact_source_validate 'Internal' >/dev/null 2>&1; then
  fail "Source internal is case-sensitive"
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

# --- Environment tree vs Source: zip must not carry Artifact contracts ---
ZIP_TREE="${TMP}/zip-wl"
mkdir -p "${ZIP_TREE}"
cat >"${ZIP_TREE}/manifest.json" <<EOF
{ "intent": "run", "source": "${zip_uri}" }
EOF
printf '{}\n' >"${ZIP_TREE}/binding.json"
artifact_source_environment_tree_gate "${ZIP_TREE}" \
  || fail "zip Environment Manifest+Binding must pass"
printf '{ "database": false }\n' >"${ZIP_TREE}/requires.json"
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

INT_TREE="${TMP}/int-wl"
mkdir -p "${INT_TREE}"
cat >"${INT_TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
printf '{}\n' >"${INT_TREE}/binding.json"
printf '{}\n' >"${INT_TREE}/provides.json"
printf '{ "database": false }\n' >"${INT_TREE}/requires.json"
artifact_source_environment_tree_gate "${INT_TREE}" \
  || fail "internal Environment Artifact contracts must pass"
pass "internal Environment Artifact contracts allowed"

# --- no dual-read of retired Manifest keys in Source helpers ---
if grep -E '\[.environment.\]|\[.database.\]|m\.get\("environment"\)|m\.get\("database"\)' \
    "${REPO_ROOT}/internals/lib/artifact/source.sh"; then
  fail "Source lib must not dual-read Manifest environment/database"
fi
pass "no Manifest environment/database dual-read"

echo "All artifact Source offline tests passed."
