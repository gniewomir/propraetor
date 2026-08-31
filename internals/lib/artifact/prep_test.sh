#!/usr/bin/env bash
# Unit tests: Artifact Prep for internal Source (ADR-0059 / #261).
# Seam: artifact_prep_internal_zip / artifact_prep_internal.
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
  printf '{"source":"internal"}\n' >"${WORKLOAD}/manifest.json"
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
[[ "${source_after}" == "${source_before}" && "${source_before}" == "internal" ]] \
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
printf '{"source":"artifact.zip"}\n' >"${WORKLOAD}/manifest.json"
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
printf '{"source":"Internal"}\n' >"${WORKLOAD}/manifest.json"
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

echo "All Artifact Prep internal unit tests passed."
