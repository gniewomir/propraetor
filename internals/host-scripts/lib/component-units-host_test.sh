#!/usr/bin/env bash
# Offline tests: Component unified systemd/ install + Quadlet dir symlink farm (ADR-0054 / #216).
# Ambient UNIT_DIR, SYSTEMD_USER_DIR, USER_NAME → temp dirs (no SSH / live Host).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=component-units-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/component-units-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/component-units.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

UNIT_DIR="${TMP}/quadlet-units"
SYSTEMD_USER_DIR="${TMP}/systemd-units"
USER_NAME="offline-test-user"
TREE="${TMP}/component"
mkdir -p "${UNIT_DIR}" "${SYSTEMD_USER_DIR}"

reset_tree() {
  rm -rf "${TREE}" "${UNIT_DIR}" "${SYSTEMD_USER_DIR}"
  mkdir -p "${UNIT_DIR}" "${SYSTEMD_USER_DIR}" "${TREE}/systemd"
}

# --- retired quadlets/ fails closed ---
reset_tree
mkdir -p "${TREE}/quadlets"
printf '[Network]\nNetworkName=x\n' >"${TREE}/systemd/ok.network"
if component_units_install "${TREE}" component demo 2>/dev/null; then
  fail "expected fail-closed when retired quadlets/ is present"
fi
pass "retired quadlets/ fails closed"

# --- unsupported extension fails closed ---
reset_tree
printf 'nope\n' >"${TREE}/systemd/bad.txt"
if component_units_install "${TREE}" component demo 2>/dev/null; then
  fail "expected fail-closed for unsupported extension"
fi
pass "unsupported extension fails closed"

# --- empty/missing systemd/ fails closed (≥1 unit) ---
rm -rf "${TREE}" "${UNIT_DIR}" "${SYSTEMD_USER_DIR}"
mkdir -p "${UNIT_DIR}" "${SYSTEMD_USER_DIR}" "${TREE}"
if component_units_install "${TREE}" component demo 2>/dev/null; then
  fail "missing systemd/ must fail"
fi
mkdir -p "${TREE}/systemd"
if component_units_install "${TREE}" component demo 2>/dev/null; then
  fail "empty systemd/ must fail"
fi
pass "missing/empty systemd/ fails closed"

# --- install: dir symlink farm for Quadlets + native copies ---
reset_tree
printf '[Network]\nNetworkName=demo\n' >"${TREE}/systemd/demo.network"
printf '[Pod]\nPodName=demo\n' >"${TREE}/systemd/demo.pod"
printf '[Service]\nType=oneshot\nExecStart=/bin/true\n' >"${TREE}/systemd/demo.service"
printf '[Timer]\nOnCalendar=daily\n' >"${TREE}/systemd/demo.timer"
component_units_install "${TREE}" component demo || fail "install should succeed"
[[ -L "${UNIT_DIR}/component-demo" ]] || fail "expected directory symlink farm entry"
[[ "$(readlink "${UNIT_DIR}/component-demo")" == "${TREE}/systemd" ]] \
  || fail "farm symlink must target owner systemd/"
[[ -f "${UNIT_DIR}/component-demo/demo.network" ]] || fail "Quadlet visible via farm"
[[ -f "${SYSTEMD_USER_DIR}/demo.service" ]] || fail "expected native service copy"
[[ -f "${SYSTEMD_USER_DIR}/demo.timer" ]] || fail "expected native timer copy"
[[ ! -f "${UNIT_DIR}/demo.network" ]] || fail "must not copy Quadlets flat into UNIT_DIR"
[[ ! -L "${UNIT_DIR}/demo.network" ]] || fail "must not create per-file Quadlet symlinks"
[[ ! -f "${SYSTEMD_USER_DIR}/demo.network" ]] || fail "network must not land in SYSTEMD_USER_DIR"
pass "install uses dir symlink farm + native copies"

# --- Fabric farm id ---
reset_tree
printf '[Network]\nNetworkName=service-network\n' >"${TREE}/systemd/service-network.network"
component_units_install "${TREE}" fabric || fail "fabric install should succeed"
[[ -L "${UNIT_DIR}/fabric" ]] || fail "expected fabric farm symlink"
[[ -f "${UNIT_DIR}/fabric/service-network.network" ]] || fail "fabric unit via farm"
pass "fabric kind uses farm id fabric"

echo "All component-units-host offline tests passed."
