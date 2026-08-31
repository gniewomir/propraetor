#!/usr/bin/env bash
# Unit tests: Artifact Prep entrypoint + environment orchestration (ADR-0059 / #264).
# Seams: artifact_prep_environment, prep.sh entrypoint, ensure-mirror/workload gates.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/artifact/prep.sh
source "${REPO_ROOT}/internals/lib/artifact/prep.sh"
# shellcheck source=lib/artifact/staging.sh
source "${REPO_ROOT}/internals/lib/artifact/staging.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/prep-entry.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

ENV_DIR="${TMP}/env"
WL_A="${ENV_DIR}/alpha"
WL_B="${ENV_DIR}/beta"
mkdir -p "${WL_A}/systemd" "${WL_B}/systemd"

setup_internal() {
  local wl_dir="${1:?}"
  printf '{ "intent": "run", "source": {"kind":"internal"} }\n' >"${wl_dir}/manifest.json"
  printf '{}\n' >"${wl_dir}/binding.json"
  printf '{ "database": false, "cache": false, "environment": {} }\n' \
    >"${wl_dir}/requires.json"
  printf '{}\n' >"${wl_dir}/provides.json"
  printf 'unit\n' >"${wl_dir}/systemd/app.container"
}

setup_internal "${WL_A}"
setup_internal "${WL_B}"

# --- gate fails before prep ---
if artifact_staging_require_all "${ENV_DIR}" >/dev/null 2>&1; then
  fail "require_all must fail closed before prep"
fi
if artifact_staging_require "${ENV_DIR}" alpha >/dev/null 2>&1; then
  fail "require must fail closed before prep"
fi
pass "staging gate fails closed before prep"

# --- artifact_prep_environment stages every Workload with manifest ---
count="$(artifact_prep_environment "${ENV_DIR}")" \
  || fail "artifact_prep_environment must succeed"
[[ "${count}" == "2" ]] || fail "prep environment must return workload count (got=${count})"
artifact_staging_require_all "${ENV_DIR}" \
  || fail "require_all must pass after prep environment"
artifact_staging_require "${ENV_DIR}" alpha >/dev/null \
  || fail "require must pass for alpha after prep"
artifact_staging_require "${ENV_DIR}" beta >/dev/null \
  || fail "require must pass for beta after prep"
pass "artifact_prep_environment discovers and preps Workloads"

# --- prep fails closed on any failure ---
BAD="${ENV_DIR}/broken"
mkdir -p "${BAD}"
printf '{ "intent": "run", "source": {"kind":"zip","path":"artifact.zip"} }\n' >"${BAD}/manifest.json"
printf '{}\n' >"${BAD}/binding.json"
printf '{}\n' >"${BAD}/provides.json"
if artifact_prep_environment "${ENV_DIR}" >/dev/null 2>&1; then
  fail "prep environment must fail closed when any Workload prep fails"
fi
pass "artifact_prep_environment fails closed on prep error"

# --- entrypoint contract ---
PREP="${REPO_ROOT}/internals/prep.sh"
[[ -f "${PREP}" ]] || fail "missing ${PREP}"
[[ -x "${PREP}" ]] || fail "prep.sh must be executable"
grep -Fq 'artifact_prep_environment' "${PREP}" \
  || fail "prep.sh must call artifact_prep_environment"
grep -Fq 'operator_dotenv_load' "${PREP}" \
  || fail "prep.sh must load operator dotenv"
grep -Fq 'operator_configuration_require' "${PREP}" \
  && fail "prep.sh must not require SSH private key" || true
pass "prep.sh entrypoint contract"

grep -Fq 'artifact_staging_require_all' \
  "${REPO_ROOT}/internals/ensure-mirror.sh" \
  || fail "ensure-mirror must gate on staging"
grep -Fq 'artifact_staging_ship_cache' \
  "${REPO_ROOT}/internals/ensure-mirror.sh" \
  || fail "ensure-mirror must ship artifact cache"
grep -Fq 'workload-materials' \
  "${REPO_ROOT}/internals/ensure-mirror.sh" \
  && fail "ensure-mirror must not stage local materials" || true
pass "ensure-mirror staging gate and cache ship"

grep -Fq 'artifact_staging_require' \
  "${REPO_ROOT}/internals/ensure-workload.sh" \
  || fail "ensure-workload must gate on staging"
grep -Fq 'artifact_prep' \
  "${REPO_ROOT}/internals/ensure-workload.sh" \
  && fail "ensure-workload must not run prep" || true
pass "ensure-workload staging gate without prep"

grep -Fq 'prep.sh' "${REPO_ROOT}/internals/ensure.sh" \
  || fail "ensure.sh must invoke prep.sh before fabric"
pass "ensure.sh invokes prep as phase 0"

echo "All Artifact Prep entrypoint checks passed."
