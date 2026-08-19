#!/usr/bin/env bash
# Offline tests: Environment Configuration three outcomes
# (ADR-0035 / ADR-0053 / #230).
# Seam: stage_for_setup / fulfill_after_materialize / apply_or_clear.
# Binding remap vs select, bag/install, ROOT_*, and containers gate stay inside.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=environment-configuration.sh
source "${REPO_ROOT}/internals/lib/environment/environment-configuration.sh"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/envcfg.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
BINDING="${TMP}/binding.json"
REQUIRES="${TMP}/requires.json"
ENV_DIR="${TMP}/env"
TREE="${TMP}/wl"
HOME_DIR="${TMP}/home"
UNIT_DIR="${TMP}/units"
WORKLOADS_ROOT="${TMP}/workloads"
USER_NAME="offline-test-user"
WL_NAME="demo"
WL_TREE="${WORKLOADS_ROOT}/${WL_NAME}"
STAGE_DIR="${TMP}/stage"
mkdir -p "${ENV_DIR}" "${TREE}" "${HOME_DIR}" "${UNIT_DIR}" \
  "${WL_TREE}/systemd" "${STAGE_DIR}"

write_empty_contract() {
  printf '{}\n' >"${BINDING}"
  printf '{ "database": false, "cache": false }\n' >"${REQUIRES}"
}

write_remap() {
  cat >"${BINDING}" <<'EOF'
{
  "environment": {
    "BAG_A": "PROC_A",
    "BAG_B": "PROC_B"
  }
}
EOF
  cat >"${REQUIRES}" <<'EOF'
{
  "environment": {
    "PROC_A": "process A",
    "PROC_B": "process B"
  },
  "database": false,
  "cache": false
}
EOF
}

envcfg_stage_and_apply() {
  local requires="${1-${REQUIRES}}"
  environment_configuration_stage_for_setup \
    "${STAGE_DIR}" "${BINDING}" "${requires}" "${ENV_DIR}" "${WL_TREE}" "${STAGE_DIR}" \
    || return 1
  environment_configuration_apply_or_clear "${WL_NAME}" "${WL_ENV_RESOLVED_REMOTE}"
}

# --- stage → apply_or_clear: bag resolve + install ---

write_remap
printf '[Container]\nImage=localhost/demo\n' >"${WL_TREE}/systemd/app.container"
printf 'BAG_A=from-file\nBAG_B=file-b\nC=surplus\n' >"${ENV_DIR}/.env"
unset BAG_A BAG_B C || true

envcfg_stage_and_apply || fail "stage→apply should succeed"
env_path="$(workload_environment_path "${WL_NAME}")"
[[ -f "${env_path}" ]] || fail "stage→apply should write EnvironmentFile"
grep -Fx 'PROC_A=from-file' "${env_path}" >/dev/null \
  || fail "EnvironmentFile should carry PROC_A from bag BAG_A"
grep -Fx 'PROC_B=file-b' "${env_path}" >/dev/null \
  || fail "EnvironmentFile should carry PROC_B from bag BAG_B"
grep -F 'surplus' "${env_path}" >/dev/null && fail "surplus must not appear in EnvironmentFile"
grep -F 'BAG_A=' "${env_path}" >/dev/null && fail "bag keys must not appear in EnvironmentFile"
app_dropin="$(workload_environment_dropin_path "app.container")"
[[ -f "${app_dropin}" ]] || fail "stage→apply should write Setup drop-in"
grep -Fx "EnvironmentFile=${env_path}" "${app_dropin}" >/dev/null \
  || fail "drop-in must wire EnvironmentFile= path only"
grep -F 'from-file' "${app_dropin}" >/dev/null && fail "values must not appear in drop-in unit text"
pass "stage→apply → EnvironmentFile + drop-ins (Requires names)"

# shell > .env.override > .env through stage
unset BAG_A BAG_B || true
printf 'BAG_A=from-file\nBAG_B=file-b\n' >"${ENV_DIR}/.env"
printf 'BAG_A=from-override\n' >"${ENV_DIR}/.env.override"
envcfg_stage_and_apply || fail "override stage→apply should succeed"
grep -Fx 'PROC_A=from-override' "${env_path}" >/dev/null \
  || fail "override should win over .env"
export BAG_A=from-shell
envcfg_stage_and_apply || fail "shell stage→apply should succeed"
grep -Fx 'PROC_A=from-shell' "${env_path}" >/dev/null \
  || fail "shell should beat .env.override"
unset BAG_A || true
rm -f "${ENV_DIR}/.env.override"
pass "stage precedence: shell > .env.override > .env"

# Sibling Database binding must survive clear (#189).
mkdir -p "$(dirname "${env_path}")/database"
printf 'keep\n' >"$(dirname "${env_path}")/database/marker"
environment_configuration_apply_or_clear "${WL_NAME}" \
  || fail "apply_or_clear empty should succeed"
[[ ! -f "${env_path}" ]] || fail "clear should remove EnvironmentFile"
[[ -f "$(dirname "${env_path}")/database/marker" ]] \
  || fail "clear must not remove sibling database/ binding"
[[ ! -f "${app_dropin}" ]] || fail "clear should remove Setup drop-in"
pass "apply_or_clear empty removes install artifacts; keeps sibling database/"

rm -rf "$(dirname "${env_path}")"
printf '[Container]\nImage=localhost/demo\n' >"${WL_TREE}/systemd/app.container"
printf '[Container]\nImage=localhost/demo-worker\n' >"${WL_TREE}/systemd/worker.container"
printf 'BAG_A=from-file\nBAG_B=file-b\n' >"${ENV_DIR}/.env"
envcfg_stage_and_apply || fail "multi-container stage→apply should succeed"
[[ -f "$(workload_environment_dropin_path "app.container")" ]] \
  || fail "expected drop-in for app.container"
[[ -f "$(workload_environment_dropin_path "worker.container")" ]] \
  || fail "expected drop-in for worker.container"
pass "stage→apply drop-ins for each SoT *.container"

# empty Requires environment → clear path through stage→apply
write_remap
printf 'BAG_A=again\nBAG_B=x\n' >"${ENV_DIR}/.env"
envcfg_stage_and_apply || fail "re-apply before empty remap should succeed"
[[ -f "${env_path}" ]] || fail "EnvironmentFile should exist before omit apply"
write_empty_contract
envcfg_stage_and_apply || fail "empty remap stage→apply should succeed"
[[ ! -f "${env_path}" ]] || fail "empty remap stage→apply should clear EnvironmentFile"
pass "stage→apply empty Requires environment → clear"

# fail closed: non-empty without containers (gate in stage prepare)
rm -f "${WL_TREE}/systemd"/*.container
write_remap
printf 'BAG_A=x\nBAG_B=y\n' >"${ENV_DIR}/.env"
if envcfg_stage_and_apply >/dev/null 2>&1; then
  fail "stage→apply without *.container should fail closed"
fi
pass "stage→apply fails closed without containers"

# fail closed: missing bag key
mkdir -p "${WL_TREE}/systemd"
printf '[Container]\nImage=localhost/demo\n' >"${WL_TREE}/systemd/app.container"
write_remap
printf 'BAG_A=only\n' >"${ENV_DIR}/.env"
if envcfg_stage_and_apply >/dev/null 2>&1; then
  fail "stage→apply with missing key should fail closed"
fi
pass "stage→apply fails closed on missing remapped key"

# fail closed: invalid dotenv
write_remap
printf 'export BAG_A=nope\nBAG_B=x\n' >"${ENV_DIR}/.env"
if envcfg_stage_and_apply >/dev/null 2>&1; then
  fail "stage→apply with export line should fail closed"
fi
printf 'BAG_A=x\nBAG_B=y\n' >"${ENV_DIR}/.env"
pass "stage→apply fails closed on invalid dotenv export"

# Reserved ROOT_* fail closed at stage (ADR-0049 / ADR-0055)
cat >"${BINDING}" <<'EOF'
{ "environment": { "ROOT_DB_USER": "PROC_A", "BAG_B": "PROC_B" } }
EOF
cat >"${REQUIRES}" <<'EOF'
{
  "environment": { "PROC_A": "a", "PROC_B": "b" },
  "database": false,
  "cache": false
}
EOF
printf 'ROOT_DB_USER=admin\nBAG_B=x\n' >"${ENV_DIR}/.env"
if envcfg_stage_and_apply >/dev/null 2>&1; then
  fail "stage→apply with ROOT_DB_USER remap should fail closed"
fi
pass "stage fails closed on ROOT_DB_* remap"

cat >"${BINDING}" <<'EOF'
{ "environment": { "ROOT_CACHE_USER": "PROC_A", "BAG_B": "PROC_B" } }
EOF
if envcfg_stage_and_apply >/dev/null 2>&1; then
  fail "stage→apply with ROOT_CACHE_USER remap should fail closed"
fi
pass "stage fails closed on ROOT_CACHE_* remap"

cat >"${BINDING}" <<'EOF'
{ "environment": { "ROOT_IDENTITY_API_KEY": "PROC_A", "BAG_B": "PROC_B" } }
EOF
if envcfg_stage_and_apply >/dev/null 2>&1; then
  fail "stage→apply with ROOT_IDENTITY_API_KEY remap should fail closed"
fi
pass "stage fails closed on ROOT_IDENTITY_* remap"

cat >"${BINDING}" <<'EOF'
{ "environment": { "BAG_A": "ROOT_IDENTITY_ADMIN_EMAIL", "BAG_B": "PROC_B" } }
EOF
cat >"${REQUIRES}" <<'EOF'
{
  "environment": { "ROOT_IDENTITY_ADMIN_EMAIL": "must not inject", "PROC_B": "b" },
  "database": false,
  "cache": false
}
EOF
printf 'BAG_A=x\nBAG_B=y\n' >"${ENV_DIR}/.env"
if envcfg_stage_and_apply >/dev/null 2>&1; then
  fail "stage with Requires name ROOT_IDENTITY_ADMIN_EMAIL must fail closed"
fi
pass "stage fails closed when Requires name is ROOT_IDENTITY_*"

cat >"${BINDING}" <<'EOF'
{ "environment": { "BAG_A": "ROOT_DB_USER", "BAG_B": "PROC_B" } }
EOF
cat >"${REQUIRES}" <<'EOF'
{
  "environment": { "ROOT_DB_USER": "must not inject", "PROC_B": "b" },
  "database": false,
  "cache": false
}
EOF
printf 'BAG_A=x\nBAG_B=y\n' >"${ENV_DIR}/.env"
if envcfg_stage_and_apply >/dev/null 2>&1; then
  fail "stage with Requires name ROOT_DB_USER must fail closed"
fi
pass "stage fails closed when Requires name is ROOT_DB_*"

# incomplete fulfill fails at stage
write_remap
cat >"${BINDING}" <<'EOF'
{ "environment": { "BAG_A": "PROC_A" } }
EOF
printf 'BAG_A=x\n' >"${ENV_DIR}/.env"
if envcfg_stage_and_apply >/dev/null 2>&1; then
  fail "incomplete Binding remap must fail closed at stage"
fi
pass "stage incomplete Binding remap fails closed"

# invalid Binding shape fails at stage
printf '{ "environment": { "BAG": 1 } }\n' >"${BINDING}"
printf '{ "database": false, "cache": false }\n' >"${REQUIRES}"
if environment_configuration_stage_for_setup \
  "${STAGE_DIR}" "${BINDING}" "${REQUIRES}" "${ENV_DIR}" "${WL_TREE}" \
  "/tmp/platform-ensure-workload" >/dev/null 2>&1; then
  fail "stage_for_setup must fail closed on invalid Binding remap"
fi
pass "stage invalid Binding fails closed"

# SSH staging adapter: stage sets WL_ENV_* globals (no stdout-eval protocol)
write_remap
printf '[Container]\nImage=localhost/demo\n' >"${WL_TREE}/systemd/app.container"
printf 'BAG_A=staged\nBAG_B=also\n' >"${ENV_DIR}/.env"
unset BAG_A BAG_B || true
environment_configuration_stage_for_setup \
  "${STAGE_DIR}" "${BINDING}" "${REQUIRES}" "${ENV_DIR}" "${WL_TREE}" \
  "/tmp/platform-ensure-workload" \
  || fail "stage_for_setup should succeed for valid remap"
[[ "${WL_ENV_ACTIVE}" == "1" ]] || fail "stage_for_setup should be active"
grep -Fx 'PROC_A=staged' "${STAGE_DIR}/environment.resolved" >/dev/null \
  || fail "stage_for_setup should write Requires names into STAGE"
[[ "${WL_ENV_RESOLVED_REMOTE}" == "/tmp/platform-ensure-workload/environment.resolved" ]] \
  || fail "expected remote resolved path, got: ${WL_ENV_RESOLVED_REMOTE}"
pass "stage_for_setup SSH staging adapter"

write_empty_contract
environment_configuration_stage_for_setup \
  "${STAGE_DIR}" "${BINDING}" "${REQUIRES}" "${ENV_DIR}" "${WL_TREE}" \
  "/tmp/platform-ensure-workload" \
  || fail "empty remap stage should succeed"
[[ "${WL_ENV_ACTIVE}" == "0" ]] || fail "empty remap stage should be inactive"
[[ -z "${WL_ENV_RESOLVED_REMOTE}" ]] || fail "empty remap stage should clear remote path"
pass "stage_for_setup empty Requires environment → inactive"

# zip Setup: Binding-only select; skip Environment-tree containers gate
write_remap
printf 'BAG_A=zip-a\nBAG_B=zip-b\n' >"${ENV_DIR}/.env"
unset BAG_A BAG_B || true
ZIP_TREE="${TMP}/zip-stage-wl"
mkdir -p "${ZIP_TREE}"
rm -rf "${ZIP_TREE}/systemd"
environment_configuration_stage_for_setup \
  "${STAGE_DIR}" "${BINDING}" "" "${ENV_DIR}" "${ZIP_TREE}" \
  "/tmp/platform-ensure-workload" \
  || fail "zip Binding-only stage should succeed without Environment Requires or systemd units"
[[ "${WL_ENV_ACTIVE}" == "1" ]] || fail "zip Binding-only stage should be active"
grep -Fx 'PROC_A=zip-a' "${STAGE_DIR}/environment.resolved" >/dev/null \
  || fail "zip stage should write Requires names into STAGE"
pass "stage zip Binding-only skips Environment Requires and quadlets"

# Binding-only ROOT_* still fails at stage
cat >"${BINDING}" <<'EOF'
{ "environment": { "ROOT_DB_USER": "PROC_A" } }
EOF
if environment_configuration_stage_for_setup \
  "${STAGE_DIR}" "${BINDING}" "" "${ENV_DIR}" "${ZIP_TREE}" \
  "/tmp/platform-ensure-workload" >/dev/null 2>&1; then
  fail "Binding-only ROOT_DB_USER remap must fail closed"
fi
pass "stage Binding-only ROOT_DB_* fails closed"

# --- fulfill_after_materialize (Host validate-only) ---

MAT="${TMP}/mat-wl"
mkdir -p "${MAT}"
printf '{}\n' >"${MAT}/binding.json"
printf '{ "database": false, "cache": false }\n' >"${MAT}/requires.json"
environment_configuration_fulfill_after_materialize "${MAT}" \
  || fail "empty Binding and Requires environment must fulfill"
pass "fulfill empty Binding/Requires"

cat >"${MAT}/binding.json" <<'EOF'
{ "environment": { "BAG_A": "PROC_A" } }
EOF
cat >"${MAT}/requires.json" <<'EOF'
{ "environment": { "PROC_A": "a" }, "database": false, "cache": false }
EOF
if environment_configuration_fulfill_after_materialize "${MAT}" >/dev/null 2>&1; then
  fail "non-empty Requires environment without .container must fail closed"
fi
mkdir -p "${MAT}/systemd"
touch "${MAT}/systemd/app.container"
environment_configuration_fulfill_after_materialize "${MAT}" \
  || fail "full-fulfill with .container must pass"
pass "fulfill non-empty Requires requires materialized systemd units"

cat >"${MAT}/binding.json" <<'EOF'
{ "environment": {} }
EOF
if environment_configuration_fulfill_after_materialize "${MAT}" >/dev/null 2>&1; then
  fail "Binding that does not full-fulfill Artifact Requires must fail closed"
fi
pass "fulfill Binding/Requires mismatch fails closed"

cat >"${MAT}/binding.json" <<'EOF'
{ "environment": { "ROOT_CACHE_PASSWORD": "PROC_A" } }
EOF
cat >"${MAT}/requires.json" <<'EOF'
{ "environment": { "PROC_A": "a" }, "database": false, "cache": false }
EOF
if environment_configuration_fulfill_after_materialize "${MAT}" >/dev/null 2>&1; then
  fail "fulfill must refuse ROOT_CACHE_* remap"
fi
pass "fulfill fails closed on ROOT_CACHE_* remap"

# install without SoT *.container still places EnvironmentFile (gate is stage/fulfill)
rm -f "${WL_TREE}/systemd"/*.container
printf 'PROC_A=x\nPROC_B=y\n' >"${STAGE_DIR}/environment.resolved"
environment_configuration_apply_or_clear "${WL_NAME}" "${STAGE_DIR}/environment.resolved" \
  || fail "apply without containers should still place EnvironmentFile"
[[ -f "$(workload_environment_path "${WL_NAME}")" ]] \
  || fail "EnvironmentFile should exist without containers"
pass "apply_or_clear without containers places EnvironmentFile (gate elsewhere)"

# no dual-read of retired Manifest environment[]
if grep -E 'm\["environment"\]|m\.get\("environment"\)|manifest\.environment' \
    "${REPO_ROOT}/internals/lib/environment/environment-configuration.sh" \
    "${REPO_ROOT}/internals/host-scripts/lib/workload-environment-host.sh"; then
  fail "Environment Configuration module must not dual-read Manifest environment[]"
fi
pass "no Manifest environment[] dual-read"

# Callers must not need remap/select/install/clear as public outcomes
if grep -E 'environment_configuration_(remap|resolve|prepare|require_containers|install_host|clear|apply_resolved|fulfill_materialized)\b' \
    "${REPO_ROOT}/internals/ensure-workload.sh" \
    "${REPO_ROOT}/internals/host-scripts/ensure-workload-host.sh" \
    "${REPO_ROOT}/internals/host-scripts/purge-orphans-host.sh"; then
  fail "Setup/Orphan Reap must call only the three outcomes"
fi
pass "Setup and Orphan Reap call only the three outcomes"

echo "All environment-configuration offline tests passed."
