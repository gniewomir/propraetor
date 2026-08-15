#!/usr/bin/env bash
# Unit tests: Workload Manifest allowlist + required Source (ADR-0053 / #200).
# Seam: artifact_manifest_validate.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=manifest.sh
source "${REPO_ROOT}/internals/lib/artifact/manifest.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/artifact-manifest.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
MANIFEST="${TMP}/manifest.json"

# --- allowlist {intent, description, source} ---
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
artifact_manifest_validate "${MANIFEST}" || fail "intent+source must pass"
pass "intent + source"

cat >"${MANIFEST}" <<'EOF'
{
  "intent": "stop",
  "description": "human only",
  "source": "internal"
}
EOF
artifact_manifest_validate "${MANIFEST}" || fail "optional description must pass"
pass "intent + description + source"

zip_uri='https://example.com/artifact.zip'
cat >"${MANIFEST}" <<EOF
{ "intent": "run", "source": "${zip_uri}" }
EOF
artifact_manifest_validate "${MANIFEST}" || fail "zip URI Source must pass"
pass "zip URI Source"

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "source": "vendor/app.zip" }
EOF
artifact_manifest_validate "${MANIFEST}" || fail "zip path Source must pass"
pass "zip path Source"

# --- Source required ---
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run" }
EOF
if artifact_manifest_validate "${MANIFEST}" >/dev/null 2>&1; then
  fail "missing Source must fail closed"
fi
pass "missing Source fails closed"

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "source": "https://example.test/bundle.tar" }
EOF
if artifact_manifest_validate "${MANIFEST}" >/dev/null 2>&1; then
  fail "non-zip Source URI must fail closed"
fi
pass "invalid Source fails closed"

# --- retired / unknown keys fail closed ---
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "source": "internal", "environment": ["A"] }
EOF
if artifact_manifest_validate "${MANIFEST}" >/dev/null 2>&1; then
  fail "Manifest environment must fail closed"
fi
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "source": "internal", "database": true }
EOF
if artifact_manifest_validate "${MANIFEST}" >/dev/null 2>&1; then
  fail "Manifest database must fail closed"
fi
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "source": "internal", "cache": true }
EOF
if artifact_manifest_validate "${MANIFEST}" >/dev/null 2>&1; then
  fail "Manifest cache must fail closed"
fi
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "source": "internal", "name": "x" }
EOF
if artifact_manifest_validate "${MANIFEST}" >/dev/null 2>&1; then
  fail "unknown Manifest key must fail closed"
fi
pass "retired and unknown keys fail closed"

# --- description type ---
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "source": "internal", "description": 1 }
EOF
if artifact_manifest_validate "${MANIFEST}" >/dev/null 2>&1; then
  fail "non-string description must fail closed"
fi
pass "non-string description fails closed"

# --- not an object ---
printf '[]\n' >"${MANIFEST}"
if artifact_manifest_validate "${MANIFEST}" >/dev/null 2>&1; then
  fail "array Manifest must fail closed"
fi
pass "non-object Manifest fails closed"

# --- no dual-read of retired Manifest keys ---
if grep -E '\[.environment.\]|\[.database.\]|\[.cache.\]|m\.get\("environment"\)|m\.get\("database"\)|m\.get\("cache"\)' \
    "${REPO_ROOT}/internals/lib/artifact/manifest.sh"; then
  fail "Manifest allowlist lib must not dual-read environment/database/cache"
fi
pass "no Manifest environment/database/cache dual-read"

# --- committed Environment Workloads are structurally valid ---
# shellcheck source=binding.sh
source "${REPO_ROOT}/internals/lib/artifact/binding.sh"

found=0
for env_dir in "${REPO_ROOT}/environments"/*; do
  [[ -d "${env_dir}" ]] || continue
  env_name="$(basename "${env_dir}")"
  [[ "${env_name}" != .* ]] || continue
  for wl_dir in "${env_dir}"/*; do
    [[ -d "${wl_dir}" ]] || continue
    wl_name="$(basename "${wl_dir}")"
    [[ "${wl_name}" != .* ]] || continue
    found=1
    label="${env_name}/${wl_name}"
    [[ -f "${wl_dir}/manifest.json" ]] || fail "${label} missing Manifest"
    [[ -f "${wl_dir}/provides.json" ]] || fail "${label} missing Provides"
    [[ -f "${wl_dir}/requires.json" ]] || fail "${label} missing Requires"
    [[ -f "${wl_dir}/binding.json" ]] || fail "${label} missing Binding"
    artifact_manifest_validate "${wl_dir}/manifest.json" \
      || fail "${label} Manifest must pass allowlist + Source"
    artifact_binding_fulfill \
      "${wl_dir}/binding.json" "${wl_dir}/provides.json" "${wl_dir}/requires.json" \
      || fail "${label} Binding must fully fulfill Provides/Requires"
  done
done
[[ "${found}" -eq 1 ]] || fail "expected committed Environment Workloads"
pass "committed Environment Workloads are structurally valid"

echo "All artifact Manifest allowlist offline tests passed."
