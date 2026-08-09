#!/usr/bin/env bash
# Offline tests: Environment Configuration declaration, resolve, and module
# interface stage→apply_resolved|clear (ADR-0035 / #129 / #132 / #140).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=environment-configuration.sh
source "${REPO_ROOT}/internals/lib/environment/environment-configuration.sh"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/envcfg.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
MANIFEST="${TMP}/manifest.json"
ENV_DIR="${TMP}/env"
OUT="${TMP}/out.env"
TREE="${TMP}/wl"
mkdir -p "${ENV_DIR}" "${TREE}"

# --- declaration surface: Manifest environment shape + container gate (#129) ---

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run" }
EOF
keys="$(environment_configuration_keys "${MANIFEST}")" || fail "omit should parse"
[[ -z "${keys}" ]] || fail "omit should yield no keys"
environment_configuration_require_containers "${TREE}" 0 || fail "inactive omit should skip gate"
pass "declaration omit → no keys, gate skipped"

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "environment": [] }
EOF
keys="$(environment_configuration_keys "${MANIFEST}")" || fail "[] should parse"
[[ -z "${keys}" ]] || fail "[] should yield no keys"
environment_configuration_require_containers "${TREE}" 0 || fail "inactive [] should skip gate"
pass "declaration [] → no keys, gate skipped"

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "environment": ["A", "B"] }
EOF
keys="$(environment_configuration_keys "${MANIFEST}")" || fail "non-empty should parse"
[[ "${keys}" == $'A\nB' ]] || fail "expected keys A then B, got: ${keys}"
if environment_configuration_require_containers "${TREE}" 1 >/dev/null 2>&1; then
  fail "non-empty without .container should fail closed"
fi
mkdir -p "${TREE}/quadlets"
touch "${TREE}/quadlets/x.container"
environment_configuration_require_containers "${TREE}" 1 || fail "should accept .container"
pass "declaration non-empty + containers gate"

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "environment": "A" }
EOF
if environment_configuration_keys "${MANIFEST}" >/dev/null 2>&1; then
  fail "non-array environment should fail closed"
fi
pass "declaration non-array fails closed"

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "environment": ["A", ""] }
EOF
if environment_configuration_keys "${MANIFEST}" >/dev/null 2>&1; then
  fail "empty-string element should fail closed"
fi
pass "declaration empty-string element fails closed"

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "environment": ["A", 1] }
EOF
if environment_configuration_keys "${MANIFEST}" >/dev/null 2>&1; then
  fail "non-string element should fail closed"
fi
pass "declaration non-string element fails closed"

# Reserved Database admin credentials must not appear on Manifest environment (ADR-0049 / #189).
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "environment": ["ROOT_DB_USER"] }
EOF
if environment_configuration_keys "${MANIFEST}" >/dev/null 2>&1; then
  fail "ROOT_DB_USER on Manifest environment must fail closed"
fi
pass "ROOT_DB_USER on Manifest environment fails closed"

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "environment": ["OK", "ROOT_DB_PASSWORD"] }
EOF
if environment_configuration_keys "${MANIFEST}" >/dev/null 2>&1; then
  fail "ROOT_DB_PASSWORD on Manifest environment must fail closed"
fi
pass "ROOT_DB_PASSWORD on Manifest environment fails closed"

# --- bag resolve (operator-side; uses declaration keys) ---

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run" }
EOF
eval "$(environment_configuration_resolve "${MANIFEST}" "${ENV_DIR}" "${OUT}")"
[[ "${WL_ENV_ACTIVE}" == "0" ]] || fail "omit environment should be inactive"
[[ ! -f "${OUT}" ]] || fail "omit should not write outfile"
pass "omit environment → inactive"

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "environment": [] }
EOF
eval "$(environment_configuration_resolve "${MANIFEST}" "${ENV_DIR}" "${OUT}")"
[[ "${WL_ENV_ACTIVE}" == "0" ]] || fail "[] should be inactive"
pass "[] environment → inactive"

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "environment": ["A", "B"] }
EOF
printf 'A=from-file\nB=file-b\nC=surplus\n' >"${ENV_DIR}/.env"
unset A B C || true
eval "$(environment_configuration_resolve "${MANIFEST}" "${ENV_DIR}" "${OUT}")"
[[ "${WL_ENV_ACTIVE}" == "1" ]] || fail "listed keys should be active"
grep -Fx 'A=from-file' "${OUT}" >/dev/null || fail "expected A from file"
grep -Fx 'B=file-b' "${OUT}" >/dev/null || fail "expected B from file"
grep -F 'surplus' "${OUT}" >/dev/null && fail "surplus must not appear"
pass ".env baseline lists only Manifest keys"

export A=from-shell
eval "$(environment_configuration_resolve "${MANIFEST}" "${ENV_DIR}" "${OUT}")"
grep -Fx 'A=from-shell' "${OUT}" >/dev/null || fail "shell should override file"
grep -Fx 'B=file-b' "${OUT}" >/dev/null || fail "B should remain from file"
pass "shell overrides .env"

unset A B || true
printf 'A=from-file\nB=file-b\n' >"${ENV_DIR}/.env"
printf 'A=from-override\n' >"${ENV_DIR}/.env.override"
eval "$(environment_configuration_resolve "${MANIFEST}" "${ENV_DIR}" "${OUT}")"
grep -Fx 'A=from-override' "${OUT}" >/dev/null || fail "override should win over .env"
grep -Fx 'B=file-b' "${OUT}" >/dev/null || fail "B from .env should remain"
export A=from-shell
eval "$(environment_configuration_resolve "${MANIFEST}" "${ENV_DIR}" "${OUT}")"
grep -Fx 'A=from-shell' "${OUT}" >/dev/null || fail "shell should beat .env.override"
unset A || true
rm -f "${ENV_DIR}/.env.override"
pass ".env.override overlays .env; shell still wins"

unset A B || true
printf 'A=only\n' >"${ENV_DIR}/.env"
if environment_configuration_resolve "${MANIFEST}" "${ENV_DIR}" "${OUT}" >/dev/null 2>&1; then
  fail "missing B should fail closed"
fi
pass "missing listed key fails closed"

printf 'export A=nope\nB=x\n' >"${ENV_DIR}/.env"
if environment_configuration_resolve "${MANIFEST}" "${ENV_DIR}" "${OUT}" >/dev/null 2>&1; then
  fail "export line should fail closed"
fi
pass "invalid dotenv export fails closed"

# --- module interface: stage_for_setup → apply_resolved | clear (#140) ---
# Same public chain as live Workload Setup; REMOTE_ROOT = STAGE so resolved path is local.
# Ambient Host dirs (offline adapter). Host half is sourced by environment-configuration.sh.

HOME_DIR="${TMP}/home"
UNIT_DIR="${TMP}/units"
WORKLOADS_ROOT="${TMP}/workloads"
USER_NAME="offline-test-user"
WL_NAME="demo"
WL_TREE="${WORKLOADS_ROOT}/${WL_NAME}"
STAGE_DIR="${TMP}/stage"
mkdir -p "${HOME_DIR}" "${UNIT_DIR}" "${WL_TREE}/quadlets" "${STAGE_DIR}"
printf '[Container]\nImage=localhost/demo\n' >"${WL_TREE}/quadlets/app.container"

# Offline helper: stage then apply_resolved (identical seam to Setup without SSH).
envcfg_stage_and_apply() {
  environment_configuration_stage_for_setup \
    "${STAGE_DIR}" "${MANIFEST}" "${ENV_DIR}" "${WL_TREE}" "${STAGE_DIR}" || return 1
  environment_configuration_apply_resolved "${WL_NAME}" "${WL_ENV_RESOLVED_REMOTE}"
}

cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "environment": ["A", "B"] }
EOF
printf 'A=from-file\nB=file-b\nC=surplus\n' >"${ENV_DIR}/.env"
unset A B C || true

envcfg_stage_and_apply || fail "stage→apply should succeed"
env_path="$(workload_environment_path "${WL_NAME}")"
[[ -f "${env_path}" ]] || fail "stage→apply should write EnvironmentFile"
grep -Fx 'A=from-file' "${env_path}" >/dev/null || fail "EnvironmentFile should carry A from bag"
grep -Fx 'B=file-b' "${env_path}" >/dev/null || fail "EnvironmentFile should carry B from bag"
grep -F 'surplus' "${env_path}" >/dev/null && fail "surplus must not appear in EnvironmentFile"
app_dropin="$(workload_environment_dropin_path "app.container")"
[[ -f "${app_dropin}" ]] || fail "stage→apply should write Setup drop-in"
grep -Fx "EnvironmentFile=${env_path}" "${app_dropin}" >/dev/null \
  || fail "drop-in must wire EnvironmentFile= path only"
grep -F 'from-file' "${app_dropin}" >/dev/null && fail "values must not appear in drop-in unit text"
pass "module stage→apply → EnvironmentFile + drop-ins"

environment_configuration_clear "${WL_NAME}" || fail "module clear should succeed"
[[ ! -f "${env_path}" ]] || fail "clear should remove EnvironmentFile"
[[ ! -e "$(dirname "${env_path}")" ]] || fail "clear should remove empty Workload config dir"
[[ ! -f "${app_dropin}" ]] || fail "clear should remove Setup drop-in"
pass "module clear removes install artifacts"

# omit / [] → clear path through stage→apply
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "environment": ["A"] }
EOF
printf 'A=again\n' >"${ENV_DIR}/.env"
envcfg_stage_and_apply || fail "re-apply before omit should succeed"
[[ -f "${env_path}" ]] || fail "EnvironmentFile should exist before omit apply"
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run" }
EOF
envcfg_stage_and_apply || fail "omit stage→apply should succeed"
[[ ! -f "${env_path}" ]] || fail "omit stage→apply should clear EnvironmentFile"
[[ ! -e "$(dirname "${env_path}")" ]] || fail "omit stage→apply should remove empty Workload config dir"
pass "module stage→apply omit → clear"

# fail closed: non-empty without containers (gate once in prepare)
rm -f "${WL_TREE}/quadlets"/*.container
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "environment": ["A"] }
EOF
printf 'A=x\n' >"${ENV_DIR}/.env"
if envcfg_stage_and_apply >/dev/null 2>&1; then
  fail "stage→apply without *.container should fail closed"
fi
pass "module stage→apply fails closed without containers"

# fail closed: missing bag key
mkdir -p "${WL_TREE}/quadlets"
printf '[Container]\nImage=localhost/demo\n' >"${WL_TREE}/quadlets/app.container"
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "environment": ["A", "B"] }
EOF
printf 'A=only\n' >"${ENV_DIR}/.env"
if envcfg_stage_and_apply >/dev/null 2>&1; then
  fail "stage→apply with missing key should fail closed"
fi
pass "module stage→apply fails closed on missing key"

# SSH staging adapter: stage_for_setup sets WL_ENV_* globals (no stdout-eval protocol)
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "environment": ["A"] }
EOF
printf 'A=staged\n' >"${ENV_DIR}/.env"
environment_configuration_stage_for_setup \
  "${STAGE_DIR}" "${MANIFEST}" "${ENV_DIR}" "${WL_TREE}" "/tmp/platform-ensure-workload" \
  || fail "stage_for_setup should succeed for valid list"
[[ "${WL_ENV_ACTIVE}" == "1" ]] || fail "stage_for_setup should be active"
grep -Fx 'A=staged' "${STAGE_DIR}/environment.resolved" >/dev/null \
  || fail "stage_for_setup should write resolved file into STAGE"
[[ "${WL_ENV_RESOLVED_REMOTE}" == "/tmp/platform-ensure-workload/environment.resolved" ]] \
  || fail "expected remote resolved path, got: ${WL_ENV_RESOLVED_REMOTE}"
pass "module stage_for_setup SSH staging adapter"

# inactive stage clears remote path
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run" }
EOF
environment_configuration_stage_for_setup \
  "${STAGE_DIR}" "${MANIFEST}" "${ENV_DIR}" "${WL_TREE}" "/tmp/platform-ensure-workload" \
  || fail "omit stage should succeed"
[[ "${WL_ENV_ACTIVE}" == "0" ]] || fail "omit stage should be inactive"
[[ -z "${WL_ENV_RESOLVED_REMOTE}" ]] || fail "omit stage should clear remote path"
pass "module stage_for_setup omit → inactive"

# fail-closed shapes must surface as non-zero from stage_for_setup (Workload Setup depends on this)
cat >"${MANIFEST}" <<'EOF'
{ "intent": "run", "environment": "A" }
EOF
if environment_configuration_stage_for_setup \
  "${STAGE_DIR}" "${MANIFEST}" "${ENV_DIR}" "${WL_TREE}" "/tmp/platform-ensure-workload" >/dev/null 2>&1; then
  fail "stage_for_setup must fail closed on non-array environment"
fi
pass "module stage_for_setup non-array fails closed"

echo "All environment-configuration offline tests passed."
