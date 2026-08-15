#!/usr/bin/env bash
# Offline tests: Host Environment Configuration install / clear / post-materialize
# fulfill (ADR-0035 / ADR-0053 / #128 / #132 / #201).
# Seam: environment_configuration_install_host / apply_resolved /
# environment_configuration_fulfill_materialized.
# Ambient HOME_DIR, UNIT_DIR, USER_NAME, WORKLOADS_ROOT → temp dirs (no SSH / live Host).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../../lib/artifact/binding.sh
source "${REPO_ROOT}/internals/lib/artifact/binding.sh"
# shellcheck source=workload-environment-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/workload-environment-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wl-env-host.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

HOME_DIR="${TMP}/home"
UNIT_DIR="${TMP}/units"
WORKLOADS_ROOT="${TMP}/workloads"
USER_NAME="offline-test-user"
WL_NAME="demo"
RESOLVED="${TMP}/resolved.env"

mkdir -p "${HOME_DIR}" "${UNIT_DIR}" "${WORKLOADS_ROOT}/${WL_NAME}/systemd"
printf 'A=from-resolved\nB=also\n' >"${RESOLVED}"
printf '[Container]\nImage=localhost/demo\n' >"${WORKLOADS_ROOT}/${WL_NAME}/systemd/app.container"
printf '[Container]\nImage=localhost/demo-worker\n' >"${WORKLOADS_ROOT}/${WL_NAME}/systemd/worker.container"

# --- install: EnvironmentFile + Setup drop-ins for each SoT *.container ---
environment_configuration_install_host "${WL_NAME}" "${RESOLVED}" \
  || fail "install should succeed with SoT containers"

env_path="$(workload_environment_path "${WL_NAME}")"
[[ -f "${env_path}" ]] || fail "expected EnvironmentFile at ${env_path}"
grep -Fx 'A=from-resolved' "${env_path}" >/dev/null || fail "EnvironmentFile should carry resolved A"
grep -Fx 'B=also' "${env_path}" >/dev/null || fail "EnvironmentFile should carry resolved B"

app_dropin="$(workload_environment_dropin_path "app.container")"
worker_dropin="$(workload_environment_dropin_path "worker.container")"
[[ -f "${app_dropin}" ]] || fail "expected Setup drop-in for app.container"
[[ -f "${worker_dropin}" ]] || fail "expected Setup drop-in for worker.container"
grep -Fx "EnvironmentFile=${env_path}" "${app_dropin}" >/dev/null \
  || fail "app drop-in must wire EnvironmentFile= to path only"
grep -Fx "EnvironmentFile=${env_path}" "${worker_dropin}" >/dev/null \
  || fail "worker drop-in must wire EnvironmentFile= to path only"
grep -F 'from-resolved' "${app_dropin}" >/dev/null && fail "values must not appear in drop-in unit text"
pass "install EnvironmentFile + drop-ins for listed containers"

# Sibling Database binding must survive Environment Configuration clear (#189).
mkdir -p "$(dirname "${env_path}")/database"
printf 'keep\n' >"$(dirname "${env_path}")/database/marker"

# --- clear on empty/omit ---
environment_configuration_clear "${WL_NAME}" \
  || fail "omit clear should succeed"
[[ ! -f "${env_path}" ]] || fail "omit should remove EnvironmentFile"
[[ -f "$(dirname "${env_path}")/database/marker" ]] \
  || fail "omit clear must not remove sibling database/ binding"
[[ ! -f "${app_dropin}" ]] || fail "omit should remove app drop-in"
[[ ! -f "${worker_dropin}" ]] || fail "omit should remove worker drop-in"
pass "clear on empty/omit"

rm -rf "$(dirname "${env_path}")"

# --- install with no SoT *.container still writes EnvironmentFile (gate is prepare's job) ---
rm -f "${WORKLOADS_ROOT}/${WL_NAME}/systemd"/*.container
environment_configuration_install_host "${WL_NAME}" "${RESOLVED}" \
  || fail "install without containers should still place EnvironmentFile"
[[ -f "${env_path}" ]] || fail "EnvironmentFile should exist without containers"
pass "install without containers places EnvironmentFile (gate elsewhere)"

# --- Orphan Reap-style clear ---
mkdir -p "${WORKLOADS_ROOT}/${WL_NAME}/systemd"
printf '[Container]\nImage=localhost/demo\n' >"${WORKLOADS_ROOT}/${WL_NAME}/systemd/app.container"
environment_configuration_install_host "${WL_NAME}" "${RESOLVED}" \
  || fail "re-install before clear should succeed"
[[ -f "${env_path}" ]] || fail "EnvironmentFile should exist before clear"
[[ -f "$(workload_environment_dropin_path "app.container")" ]] \
  || fail "drop-in should exist before clear"

environment_configuration_clear "${WL_NAME}" \
  || fail "Orphan Reap-style clear should succeed"
[[ ! -f "${env_path}" ]] || fail "clear should remove EnvironmentFile"
[[ ! -e "$(dirname "${env_path}")" ]] || fail "clear should remove empty Workload config dir"
[[ ! -f "$(workload_environment_dropin_path "app.container")" ]] \
  || fail "clear should remove Setup drop-in"
pass "Orphan Reap-style clear"

# --- post-materialize Binding × Artifact Requires full-fulfill ---
MAT="${TMP}/mat-wl"
mkdir -p "${MAT}"
printf '{}\n' >"${MAT}/binding.json"
printf '{ "database": false, "cache": false }\n' >"${MAT}/requires.json"
environment_configuration_fulfill_materialized "${MAT}" \
  || fail "empty Binding and Requires environment must fulfill"
pass "fulfill empty Binding/Requires"

cat >"${MAT}/binding.json" <<'EOF'
{ "environment": { "BAG_A": "PROC_A" } }
EOF
cat >"${MAT}/requires.json" <<'EOF'
{ "environment": { "PROC_A": "a" }, "database": false, "cache": false }
EOF
if environment_configuration_fulfill_materialized "${MAT}" >/dev/null 2>&1; then
  fail "non-empty Requires environment without .container must fail closed"
fi
mkdir -p "${MAT}/systemd"
touch "${MAT}/systemd/app.container"
environment_configuration_fulfill_materialized "${MAT}" \
  || fail "full-fulfill with .container must pass"
pass "fulfill non-empty Requires requires materialized systemd units"

cat >"${MAT}/binding.json" <<'EOF'
{ "environment": {} }
EOF
if environment_configuration_fulfill_materialized "${MAT}" >/dev/null 2>&1; then
  fail "Binding that does not full-fulfill Artifact Requires must fail closed"
fi
pass "fulfill Binding/Requires mismatch fails closed"

echo "All workload-environment-host offline tests passed."
