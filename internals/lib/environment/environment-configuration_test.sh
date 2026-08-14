#!/usr/bin/env bash
# Offline tests: Environment Configuration Binding×Requires resolve and
# module interface stage→apply_resolved|clear (ADR-0035 / ADR-0053 / #201).
# Seam: environment_configuration_remap / resolve / stage_for_setup.
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
OUT="${TMP}/out.env"
TREE="${TMP}/wl"
mkdir -p "${ENV_DIR}" "${TREE}"

write_empty_contract() {
  printf '{}\n' >"${BINDING}"
  printf '{ "database": false }\n' >"${REQUIRES}"
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
  "database": false
}
EOF
}

# --- declaration surface: Binding×Requires remap + container gate ---

write_empty_contract
pairs="$(environment_configuration_remap "${BINDING}" "${REQUIRES}")" \
  || fail "empty Requires environment should parse"
[[ -z "${pairs}" ]] || fail "empty Requires environment should yield no pairs"
environment_configuration_require_containers "${TREE}" 0 \
  || fail "inactive empty remap should skip gate"
pass "declaration empty Requires environment → no pairs, gate skipped"

write_remap
pairs="$(environment_configuration_remap "${BINDING}" "${REQUIRES}")" \
  || fail "non-empty remap should parse"
[[ "${pairs}" == $'BAG_A=PROC_A\nBAG_B=PROC_B' ]] \
  || fail "expected BAG_A=PROC_A then BAG_B=PROC_B, got: ${pairs}"
if environment_configuration_require_containers "${TREE}" 1 >/dev/null 2>&1; then
  fail "non-empty Requires environment without .container should fail closed"
fi
mkdir -p "${TREE}/quadlets"
touch "${TREE}/quadlets/x.container"
environment_configuration_require_containers "${TREE}" 1 \
  || fail "should accept .container"
pass "declaration non-empty remap + containers gate"

# Reserved Database admin credentials must not be Binding-remapped (ADR-0049 / #201).
cat >"${BINDING}" <<'EOF'
{ "environment": { "ROOT_DB_USER": "PROC_A", "BAG_B": "PROC_B" } }
EOF
if environment_configuration_remap "${BINDING}" "${REQUIRES}" >/dev/null 2>&1; then
  fail "ROOT_DB_USER remapped into a Workload must fail closed"
fi
pass "ROOT_DB_USER remapped into a Workload fails closed"

cat >"${BINDING}" <<'EOF'
{ "environment": { "BAG_A": "PROC_A", "ROOT_DB_PASSWORD": "PROC_B" } }
EOF
if environment_configuration_remap "${BINDING}" "${REQUIRES}" >/dev/null 2>&1; then
  fail "ROOT_DB_PASSWORD remapped into a Workload must fail closed"
fi
pass "ROOT_DB_PASSWORD remapped into a Workload fails closed"

cat >"${BINDING}" <<'EOF'
{ "environment": { "BAG_A": "ROOT_DB_USER", "BAG_B": "PROC_B" } }
EOF
cat >"${REQUIRES}" <<'EOF'
{
  "environment": { "ROOT_DB_USER": "must not inject", "PROC_B": "b" },
  "database": false
}
EOF
if environment_configuration_remap "${BINDING}" "${REQUIRES}" >/dev/null 2>&1; then
  fail "Requires name ROOT_DB_USER must fail closed"
fi
pass "Requires name ROOT_DB_USER fails closed"

write_remap
# Incomplete fulfill still fails via Binding lib
cat >"${BINDING}" <<'EOF'
{ "environment": { "BAG_A": "PROC_A" } }
EOF
if environment_configuration_remap "${BINDING}" "${REQUIRES}" >/dev/null 2>&1; then
  fail "missing Requires remap RHS must fail closed"
fi
pass "incomplete Binding remap fails closed"

# Binding-only remap (zip): no Requires file; ROOT_DB still fail closed.
write_remap
pairs="$(environment_configuration_remap "${BINDING}")" \
  || fail "Binding-only remap should parse"
[[ "${pairs}" == $'BAG_A=PROC_A\nBAG_B=PROC_B' ]] \
  || fail "expected BAG_A=PROC_A then BAG_B=PROC_B without Requires, got: ${pairs}"
pass "declaration Binding-only remap (no Requires)"

cat >"${BINDING}" <<'EOF'
{ "environment": { "ROOT_DB_USER": "PROC_A" } }
EOF
if environment_configuration_remap "${BINDING}" >/dev/null 2>&1; then
  fail "ROOT_DB_USER remapped Binding-only must fail closed"
fi
pass "Binding-only ROOT_DB_USER remap fails closed"

# --- bag resolve (operator-side; Binding bag keys → Requires names) ---

write_empty_contract
eval "$(environment_configuration_resolve "${BINDING}" "${REQUIRES}" "${ENV_DIR}" "${OUT}")"
[[ "${WL_ENV_ACTIVE}" == "0" ]] || fail "empty Requires environment should be inactive"
[[ ! -f "${OUT}" ]] || fail "empty remap should not write outfile"
pass "empty Requires environment → inactive"

write_remap
printf 'BAG_A=from-file\nBAG_B=file-b\nC=surplus\n' >"${ENV_DIR}/.env"
unset BAG_A BAG_B C PROC_A PROC_B || true
eval "$(environment_configuration_resolve "${BINDING}" "${REQUIRES}" "${ENV_DIR}" "${OUT}")"
[[ "${WL_ENV_ACTIVE}" == "1" ]] || fail "remapped keys should be active"
grep -Fx 'PROC_A=from-file' "${OUT}" >/dev/null || fail "expected PROC_A from bag BAG_A"
grep -Fx 'PROC_B=file-b' "${OUT}" >/dev/null || fail "expected PROC_B from bag BAG_B"
grep -F 'surplus' "${OUT}" >/dev/null && fail "surplus must not appear"
grep -F 'BAG_A=' "${OUT}" >/dev/null && fail "bag key names must not appear in EnvironmentFile"
pass ".env baseline lists only Requires names"

export BAG_A=from-shell
eval "$(environment_configuration_resolve "${BINDING}" "${REQUIRES}" "${ENV_DIR}" "${OUT}")"
grep -Fx 'PROC_A=from-shell' "${OUT}" >/dev/null || fail "shell should override file (bag key)"
grep -Fx 'PROC_B=file-b' "${OUT}" >/dev/null || fail "PROC_B should remain from file"
pass "shell overrides .env on bag keys"

unset BAG_A BAG_B || true
printf 'BAG_A=from-file\nBAG_B=file-b\n' >"${ENV_DIR}/.env"
printf 'BAG_A=from-override\n' >"${ENV_DIR}/.env.override"
eval "$(environment_configuration_resolve "${BINDING}" "${REQUIRES}" "${ENV_DIR}" "${OUT}")"
grep -Fx 'PROC_A=from-override' "${OUT}" >/dev/null || fail "override should win over .env"
grep -Fx 'PROC_B=file-b' "${OUT}" >/dev/null || fail "PROC_B from .env should remain"
export BAG_A=from-shell
eval "$(environment_configuration_resolve "${BINDING}" "${REQUIRES}" "${ENV_DIR}" "${OUT}")"
grep -Fx 'PROC_A=from-shell' "${OUT}" >/dev/null || fail "shell should beat .env.override"
unset BAG_A || true
rm -f "${ENV_DIR}/.env.override"
pass ".env.override overlays .env; shell still wins"

unset BAG_A BAG_B || true
printf 'BAG_A=only\n' >"${ENV_DIR}/.env"
if environment_configuration_resolve "${BINDING}" "${REQUIRES}" "${ENV_DIR}" "${OUT}" \
  >/dev/null 2>&1; then
  fail "missing BAG_B should fail closed"
fi
pass "missing remapped bag key fails closed"

printf 'export BAG_A=nope\nBAG_B=x\n' >"${ENV_DIR}/.env"
if environment_configuration_resolve "${BINDING}" "${REQUIRES}" "${ENV_DIR}" "${OUT}" \
  >/dev/null 2>&1; then
  fail "export line should fail closed"
fi
pass "invalid dotenv export fails closed"

# --- module interface: stage_for_setup → apply_resolved | clear (#140 / #201) ---
HOME_DIR="${TMP}/home"
UNIT_DIR="${TMP}/units"
WORKLOADS_ROOT="${TMP}/workloads"
USER_NAME="offline-test-user"
WL_NAME="demo"
WL_TREE="${WORKLOADS_ROOT}/${WL_NAME}"
STAGE_DIR="${TMP}/stage"
mkdir -p "${HOME_DIR}" "${UNIT_DIR}" "${WL_TREE}/quadlets" "${STAGE_DIR}"
printf '[Container]\nImage=localhost/demo\n' >"${WL_TREE}/quadlets/app.container"

envcfg_stage_and_apply() {
  environment_configuration_stage_for_setup \
    "${STAGE_DIR}" "${BINDING}" "${REQUIRES}" "${ENV_DIR}" "${WL_TREE}" "${STAGE_DIR}" \
    || return 1
  environment_configuration_apply_resolved "${WL_NAME}" "${WL_ENV_RESOLVED_REMOTE}"
}

write_remap
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
pass "module stage→apply → EnvironmentFile + drop-ins (Requires names)"

environment_configuration_clear "${WL_NAME}" || fail "module clear should succeed"
[[ ! -f "${env_path}" ]] || fail "clear should remove EnvironmentFile"
[[ ! -e "$(dirname "${env_path}")" ]] || fail "clear should remove empty Workload config dir"
[[ ! -f "${app_dropin}" ]] || fail "clear should remove Setup drop-in"
pass "module clear removes install artifacts"

# empty Requires environment → clear path through stage→apply
write_remap
printf 'BAG_A=again\nBAG_B=x\n' >"${ENV_DIR}/.env"
envcfg_stage_and_apply || fail "re-apply before empty remap should succeed"
[[ -f "${env_path}" ]] || fail "EnvironmentFile should exist before omit apply"
write_empty_contract
envcfg_stage_and_apply || fail "empty remap stage→apply should succeed"
[[ ! -f "${env_path}" ]] || fail "empty remap stage→apply should clear EnvironmentFile"
[[ ! -e "$(dirname "${env_path}")" ]] || fail "empty remap stage→apply should remove empty Workload config dir"
pass "module stage→apply empty Requires environment → clear"

# fail closed: non-empty without containers (gate once in prepare)
rm -f "${WL_TREE}/quadlets"/*.container
write_remap
printf 'BAG_A=x\nBAG_B=y\n' >"${ENV_DIR}/.env"
if envcfg_stage_and_apply >/dev/null 2>&1; then
  fail "stage→apply without *.container should fail closed"
fi
pass "module stage→apply fails closed without containers"

# fail closed: missing bag key
mkdir -p "${WL_TREE}/quadlets"
printf '[Container]\nImage=localhost/demo\n' >"${WL_TREE}/quadlets/app.container"
write_remap
printf 'BAG_A=only\n' >"${ENV_DIR}/.env"
if envcfg_stage_and_apply >/dev/null 2>&1; then
  fail "stage→apply with missing key should fail closed"
fi
pass "module stage→apply fails closed on missing remapped key"

# fail closed: ROOT_DB_* remap at stage
cat >"${BINDING}" <<'EOF'
{ "environment": { "ROOT_DB_USER": "PROC_A", "BAG_B": "PROC_B" } }
EOF
cat >"${REQUIRES}" <<'EOF'
{
  "environment": { "PROC_A": "a", "PROC_B": "b" },
  "database": false
}
EOF
printf 'ROOT_DB_USER=admin\nBAG_B=x\n' >"${ENV_DIR}/.env"
if envcfg_stage_and_apply >/dev/null 2>&1; then
  fail "stage→apply with ROOT_DB_USER remap should fail closed"
fi
pass "module stage→apply fails closed on ROOT_DB_* remap"

# SSH staging adapter: stage_for_setup sets WL_ENV_* globals (no stdout-eval protocol)
write_remap
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
pass "module stage_for_setup SSH staging adapter"

# inactive stage clears remote path
write_empty_contract
environment_configuration_stage_for_setup \
  "${STAGE_DIR}" "${BINDING}" "${REQUIRES}" "${ENV_DIR}" "${WL_TREE}" \
  "/tmp/platform-ensure-workload" \
  || fail "empty remap stage should succeed"
[[ "${WL_ENV_ACTIVE}" == "0" ]] || fail "empty remap stage should be inactive"
[[ -z "${WL_ENV_RESOLVED_REMOTE}" ]] || fail "empty remap stage should clear remote path"
pass "module stage_for_setup empty Requires environment → inactive"

# fail-closed shapes must surface as non-zero from stage_for_setup
printf '{ "environment": { "BAG": 1 } }\n' >"${BINDING}"
printf '{ "database": false }\n' >"${REQUIRES}"
if environment_configuration_stage_for_setup \
  "${STAGE_DIR}" "${BINDING}" "${REQUIRES}" "${ENV_DIR}" "${WL_TREE}" \
  "/tmp/platform-ensure-workload" >/dev/null 2>&1; then
  fail "stage_for_setup must fail closed on invalid Binding remap"
fi
pass "module stage_for_setup invalid Binding fails closed"

# zip Setup: no Environment Requires; Binding-only stage; skip Environment-tree containers gate
write_remap
printf 'BAG_A=zip-a\nBAG_B=zip-b\n' >"${ENV_DIR}/.env"
unset BAG_A BAG_B || true
ZIP_TREE="${TMP}/zip-stage-wl"
mkdir -p "${ZIP_TREE}"
rm -rf "${ZIP_TREE}/quadlets"
environment_configuration_stage_for_setup \
  "${STAGE_DIR}" "${BINDING}" "" "${ENV_DIR}" "${ZIP_TREE}" \
  "/tmp/platform-ensure-workload" \
  || fail "zip Binding-only stage should succeed without Environment Requires or quadlets"
[[ "${WL_ENV_ACTIVE}" == "1" ]] || fail "zip Binding-only stage should be active"
grep -Fx 'PROC_A=zip-a' "${STAGE_DIR}/environment.resolved" >/dev/null \
  || fail "zip stage should write Requires names into STAGE"
pass "module stage_for_setup zip Binding-only skips Environment Requires and quadlets"

# no dual-read of retired Manifest environment[]
if grep -E 'm\["environment"\]|m\.get\("environment"\)|manifest\.environment' \
    "${REPO_ROOT}/internals/lib/environment/environment-configuration.sh" \
    "${REPO_ROOT}/internals/lib/environment/environment-configuration-declaration.sh"; then
  fail "Environment Configuration module must not dual-read Manifest environment[]"
fi
pass "no Manifest environment[] dual-read"

echo "All environment-configuration offline tests passed."
