#!/usr/bin/env bash
# Offline tests: Workload unified systemd/ apply / farm / purge (ADR-0054 / #216).
# Ambient UNIT_DIR, SYSTEMD_USER_DIR, WORKLOADS_ROOT, USER_NAME → temp dirs.
# Stubs quadlet_user / quadlet_user_session_reload at the session boundary.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=workload-units-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/workload-units-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/workload-units.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

UNIT_DIR="${TMP}/quadlet-units"
SYSTEMD_USER_DIR="${TMP}/systemd-units"
WORKLOADS_ROOT="${TMP}/workloads"
USER_NAME=""
WL_NAME="demo"
QUADLET_LOG="${TMP}/quadlet.log"

quadlet_user() {
  printf '%s\n' "$*" >>"${QUADLET_LOG}"
  if [[ "$*" == *"--quiet is-active"* ]] || [[ "$*" == *" is-active "* ]]; then
    return 0
  fi
  return 0
}

quadlet_user_session_reload() {
  printf 'daemon-reload\n' >>"${QUADLET_LOG}"
}

reset() {
  rm -rf "${UNIT_DIR}" "${SYSTEMD_USER_DIR}" "${WORKLOADS_ROOT}" "${TMP}/stage" "${QUADLET_LOG}"
  mkdir -p "${UNIT_DIR}" "${SYSTEMD_USER_DIR}" "${WORKLOADS_ROOT}" "${TMP}/stage/systemd"
  : >"${QUADLET_LOG}"
  unset -f workload_units_before_reload 2>/dev/null || true
}

SYSTEMD_STAGE="${TMP}/stage/systemd"

# --- retired quadlets/ on stage fails closed ---
reset
mkdir -p "${TMP}/stage/quadlets"
printf '[Container]\nImage=localhost/x\n' >"${SYSTEMD_STAGE}/ok.container"
if workload_units_apply "${WL_NAME}" run "${SYSTEMD_STAGE}" 2>/dev/null; then
  fail "expected fail-closed when stage has retired quadlets/"
fi
pass "retired quadlets/ on stage fails closed"

# --- unsupported extension fails closed ---
reset
printf 'x\n' >"${SYSTEMD_STAGE}/bad.txt"
if workload_units_apply "${WL_NAME}" stop "${SYSTEMD_STAGE}" 2>/dev/null; then
  fail "expected fail-closed for unsupported extension"
fi
pass "unsupported extension fails closed"

# --- empty bag fails closed ---
reset
if workload_units_apply "${WL_NAME}" stop "${SYSTEMD_STAGE}" 2>/dev/null; then
  fail "empty systemd/ must fail"
fi
pass "empty systemd/ fails closed"

# --- apply: farm dir symlink + native copies + SoT sync ---
reset
printf '[Network]\nNetworkName=demo\n' >"${SYSTEMD_STAGE}/demo.network"
printf '[Container]\nImage=localhost/demo\n' >"${SYSTEMD_STAGE}/demo.container"
printf '[Service]\nType=oneshot\nExecStart=/bin/true\n' >"${SYSTEMD_STAGE}/demo.service"
printf '[Timer]\nOnCalendar=daily\n' >"${SYSTEMD_STAGE}/demo.timer"
workload_units_apply "${WL_NAME}" stop "${SYSTEMD_STAGE}" ||
  fail "apply should succeed for unified bag"
[[ -L "${UNIT_DIR}/workload-demo" ]] || fail "expected workload farm symlink"
[[ "$(readlink "${UNIT_DIR}/workload-demo")" == "${WORKLOADS_ROOT}/${WL_NAME}/systemd" ]] \
  || fail "farm must point at Host Volume systemd/"
[[ -f "${UNIT_DIR}/workload-demo/demo.container" ]] || fail "Quadlet via farm"
[[ -f "${SYSTEMD_USER_DIR}/demo.service" ]] || fail "native service copy"
[[ -f "${SYSTEMD_USER_DIR}/demo.timer" ]] || fail "native timer copy"
[[ ! -f "${UNIT_DIR}/demo.container" ]] || fail "must not flat-copy Quadlets"
[[ ! -L "${UNIT_DIR}/demo.container" ]] || fail "must not per-file symlink Quadlets"
[[ -f "${WORKLOADS_ROOT}/${WL_NAME}/systemd/demo.container" ]] || fail "SoT systemd sync"
[[ ! -d "${WORKLOADS_ROOT}/${WL_NAME}/quadlets" ]] || fail "must not invent quadlets/ SoT"
pass "apply installs farm + natives and syncs SoT"

# --- basename ownership: foreign basename already visible via another farm ---
reset
mkdir -p "${UNIT_DIR}/component-edge"
printf '[Container]\nImage=localhost/foreign\n' >"${UNIT_DIR}/component-edge/taken.container"
printf '[Container]\nImage=localhost/mine\n' >"${SYSTEMD_STAGE}/taken.container"
if workload_units_apply "${WL_NAME}" run "${SYSTEMD_STAGE}" 2>/dev/null; then
  fail "expected fail-closed when Host already has foreign basename"
fi
[[ ! -d "${WORKLOADS_ROOT}/${WL_NAME}/systemd" ]] ||
  fail "foreign collision must not sync SoT before refuse"
pass "basename ownership: foreign farm basename refused"

# --- purge removes farm symlink + natives + drop-ins; leaves SoT alone ---
reset
printf '[Container]\nImage=localhost/app\n' >"${SYSTEMD_STAGE}/app.container"
printf '[Service]\nType=oneshot\nExecStart=/bin/true\n' >"${SYSTEMD_STAGE}/app.service"
workload_units_apply "${WL_NAME}" stop "${SYSTEMD_STAGE}" || fail "apply before purge"
mkdir -p "${UNIT_DIR}/app.container.d"
printf 'dropin\n' >"${UNIT_DIR}/app.container.d/50-platform-environment.conf"
[[ -L "${UNIT_DIR}/workload-demo" ]] || fail "precondition: farm present"
workload_units_purge "${WL_NAME}" || fail "purge should succeed"
[[ ! -e "${UNIT_DIR}/workload-demo" ]] || fail "purge must remove farm symlink"
[[ ! -e "${UNIT_DIR}/app.container.d" ]] || fail "purge must remove flat drop-in dir"
[[ ! -f "${SYSTEMD_USER_DIR}/app.service" ]] || fail "purge must remove native copy"
[[ -f "${WORKLOADS_ROOT}/${WL_NAME}/systemd/app.container" ]] ||
  fail "purge must not delete Host Volume SoT through the farm"
pass "purge removes farm + natives + drop-ins; keeps SoT"

# --- Intent run restarts Always-on container ---
reset
printf '[Container]\nImage=localhost/app\n' >"${SYSTEMD_STAGE}/app.container"
workload_units_apply "${WL_NAME}" run "${SYSTEMD_STAGE}" || fail "run apply"
grep -Fq 'restart app.service' "${QUADLET_LOG}" || fail "run should restart Always-on"
pass "Intent run restarts Always-on"

# --- before_reload hook runs ---
reset
printf '[Container]\nImage=localhost/app\n' >"${SYSTEMD_STAGE}/app.container"
HOOK_LOG="${TMP}/hook.log"
workload_units_before_reload() {
  printf 'hook\n' >>"${HOOK_LOG}"
}
workload_units_apply "${WL_NAME}" stop "${SYSTEMD_STAGE}" || fail "apply with hook"
[[ -f "${HOOK_LOG}" ]] || fail "before_reload hook must run"
pass "before_reload hook runs"

echo "All workload-units-host offline tests passed."
