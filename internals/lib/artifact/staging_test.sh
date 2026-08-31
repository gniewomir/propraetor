#!/usr/bin/env bash
# Unit tests: Artifact staging + cache contract (ADR-0059 / #260).
# Seam: artifact_cache_dir / artifact_staging_zip_basename /
# artifact_staging_write / artifact_staging_read.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=staging.sh
source "${REPO_ROOT}/internals/lib/artifact/staging.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/artifact-staging.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

ENV_ROOT="${TMP}/env"
ZIP_SRC="${TMP}/source.zip"
BASENAME="panel"

mkdir -p "${ENV_ROOT}"
python3 - "${ZIP_SRC}" <<'PY'
import zipfile
import sys

with zipfile.ZipFile(sys.argv[1], "w") as zf:
    zf.writestr("artifact-bytes", "artifact-bytes\n")
PY

# --- cache dir ---
[[ "$(artifact_cache_dir "${ENV_ROOT}")" == "${ENV_ROOT}/.artifact-cache" ]] \
  || fail "artifact_cache_dir path"
pass "artifact_cache_dir"

# --- zip basename ---
SHA64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
[[ "$(artifact_staging_zip_basename panel "${SHA64}")" \
  == "panel-${SHA64}.zip" ]] \
  || fail "artifact_staging_zip_basename"
pass "artifact_staging_zip_basename"

# --- happy path write + read ---
sha="$(artifact_staging_write "${ENV_ROOT}" "${BASENAME}" "${ZIP_SRC}")" \
  || fail "artifact_staging_write must succeed"
[[ "${sha}" =~ ^[0-9a-f]{64}$ ]] || fail "write must print lowercase sha256"
expected_zip="$(python3 - "${ENV_ROOT}" "${BASENAME}" "${sha}" <<'PY'
import sys
from pathlib import Path

env = Path(sys.argv[1])
basename = sys.argv[2]
sha = sys.argv[3]
print(str((env / ".artifact-cache" / f"{basename}-{sha}.zip").resolve()))
PY
)"
[[ -f "${expected_zip}" ]] || fail "content-addressed zip must exist"
[[ -f "${ENV_ROOT}/.artifact-cache/${BASENAME}.staging" ]] \
  || fail "staging file must exist"
staging_body="$(tr -d '\n' <"${ENV_ROOT}/.artifact-cache/${BASENAME}.staging")"
[[ "${staging_body}" == "${sha}" ]] || fail "staging file must contain sha256 only"
got="$(artifact_staging_read "${ENV_ROOT}" "${BASENAME}")" \
  || fail "artifact_staging_read must succeed"
[[ "${got}" == "${expected_zip}" ]] || fail "read must return absolute zip path (got=${got} expected=${expected_zip})"
pass "write + read happy path"

# --- write is idempotent for same bytes ---
sha2="$(artifact_staging_write "${ENV_ROOT}" "${BASENAME}" "${ZIP_SRC}")" \
  || fail "second write must succeed"
[[ "${sha2}" == "${sha}" ]] || fail "same zip bytes must yield same sha256"
pass "write idempotent checksum"

# --- basename validation (write) ---
if artifact_staging_write "${ENV_ROOT}" '' "${ZIP_SRC}" >/dev/null 2>&1; then
  fail "empty basename must fail closed on write"
fi
if artifact_staging_write "${ENV_ROOT}" '../escape' "${ZIP_SRC}" >/dev/null 2>&1; then
  fail "basename with .. must fail closed on write"
fi
if artifact_staging_write "${ENV_ROOT}" 'a/b' "${ZIP_SRC}" >/dev/null 2>&1; then
  fail "basename with path separator must fail closed on write"
fi
pass "basename validation on write"

# --- missing zip source ---
if artifact_staging_write "${ENV_ROOT}" other "${TMP}/missing.zip" >/dev/null 2>&1; then
  fail "missing zip source must fail closed on write"
fi
pass "missing zip source on write"

# --- read fail closed: missing staging ---
OTHER="analytics"
if artifact_staging_read "${ENV_ROOT}" "${OTHER}" >/dev/null 2>&1; then
  fail "missing staging must fail closed on read"
fi
pass "missing staging on read"

# --- read fail closed: empty staging ---
mkdir -p "${ENV_ROOT}/.artifact-cache"
: >"${ENV_ROOT}/.artifact-cache/${OTHER}.staging"
if artifact_staging_read "${ENV_ROOT}" "${OTHER}" >/dev/null 2>&1; then
  fail "empty staging must fail closed on read"
fi
pass "empty staging on read"

# --- read fail closed: wrong length ---
printf 'abc\n' >"${ENV_ROOT}/.artifact-cache/${OTHER}.staging"
if artifact_staging_read "${ENV_ROOT}" "${OTHER}" >/dev/null 2>&1; then
  fail "short staging must fail closed on read"
fi
pass "wrong-length staging on read"

# --- read fail closed: non-hex ---
python3 - "${ENV_ROOT}/.artifact-cache/${OTHER}.staging" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text("g" * 64 + "\n", encoding="utf-8")
PY
if artifact_staging_read "${ENV_ROOT}" "${OTHER}" >/dev/null 2>&1; then
  fail "non-hex staging must fail closed on read"
fi
pass "non-hex staging on read"

# --- read fail closed: extra lines ---
printf '%s\nextra\n' "${sha}" >"${ENV_ROOT}/.artifact-cache/${OTHER}.staging"
if artifact_staging_read "${ENV_ROOT}" "${OTHER}" >/dev/null 2>&1; then
  fail "multi-line staging must fail closed on read"
fi
pass "extra lines in staging on read"

# --- read fail closed: missing referenced zip ---
printf '%s\n' "${sha}" >"${ENV_ROOT}/.artifact-cache/${OTHER}.staging"
if artifact_staging_read "${ENV_ROOT}" "${OTHER}" >/dev/null 2>&1; then
  fail "staging without zip must fail closed on read"
fi
pass "missing referenced zip on read"

# --- basename validation (read) ---
if artifact_staging_read "${ENV_ROOT}" '' >/dev/null 2>&1; then
  fail "empty basename must fail closed on read"
fi
pass "basename validation on read"

# --- require (gate) ---
artifact_staging_require "${ENV_ROOT}" "${BASENAME}" \
  || fail "require must succeed when staging is valid"
if artifact_staging_require "${ENV_ROOT}" "${OTHER}" >/dev/null 2>&1; then
  fail "require must fail closed without staging"
fi
pass "artifact_staging_require gate"

# --- require_all + ship_cache ---
ENV2="${TMP}/env2"
WL_A="${ENV2}/alpha"
WL_B="${ENV2}/beta"
mkdir -p "${WL_A}" "${WL_B}"
printf '{ "intent": "run", "source": {"kind":"internal"} }\n' >"${WL_A}/manifest.json"
printf '{}\n' >"${WL_A}/binding.json"
printf '{ "database": false, "cache": false, "environment": {} }\n' \
  >"${WL_A}/requires.json"
printf '{}\n' >"${WL_A}/provides.json"
printf '{ "intent": "run", "source": {"kind":"internal"} }\n' >"${WL_B}/manifest.json"
printf '{}\n' >"${WL_B}/binding.json"
printf '{ "database": false, "cache": false, "environment": {} }\n' \
  >"${WL_B}/requires.json"
printf '{}\n' >"${WL_B}/provides.json"

if artifact_staging_require_all "${ENV2}" >/dev/null 2>&1; then
  fail "require_all must fail closed before prep"
fi
artifact_staging_write "${ENV2}" alpha "${ZIP_SRC}" >/dev/null \
  || fail "seed alpha staging"
if artifact_staging_require_all "${ENV2}" >/dev/null 2>&1; then
  fail "require_all must fail closed when any Workload lacks staging"
fi
artifact_staging_write "${ENV2}" beta "${ZIP_SRC}" >/dev/null \
  || fail "seed beta staging"
artifact_staging_require_all "${ENV2}" \
  || fail "require_all must succeed when every Workload is staged"

SHIP_DEST="${TMP}/ship"
mkdir -p "${SHIP_DEST}"
artifact_staging_ship_cache "${ENV2}" "${SHIP_DEST}" \
  || fail "ship_cache must succeed"
[[ -f "${SHIP_DEST}/.artifact-cache/alpha.staging" ]] \
  || fail "ship_cache must copy staging records"
[[ -f "${SHIP_DEST}/.artifact-cache/beta.staging" ]] \
  || fail "ship_cache must copy all staging records"
pass "artifact_staging_require_all and ship_cache"

echo "All artifact staging offline tests passed."
