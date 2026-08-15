#!/usr/bin/env bash
# Unit tests: host_wait_until_ihp_done retries SSH 255 across ADR-0030 reboot.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=ihp.sh
source "${REPO_ROOT}/internals/lib/ihp.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

STUBS="$(mktemp -d "${TMPDIR:-/tmp}/ihp-op.XXXXXX")"
trap 'rm -rf "${STUBS}"' EXIT
SCRIPT="${STUBS}/wait.sh"
printf '#!/bin/true\n' >"${SCRIPT}"
chmod +x "${SCRIPT}"
# Operator delivery prepends sibling Host Volume path helpers (bash -s has no BASH_SOURCE).
mkdir -p "${STUBS}/lib"
printf 'host_volume_mount_root() { printf /host-volume\\n; }\n' >"${STUBS}/lib/host-volume-paths-host.sh"

CALLS="${STUBS}/calls"
: >"${CALLS}"

# Fail twice with 255, then succeed. Capture stdin so we can assert lib prepend.
host_ssh() {
  local n
  cat >"${STUBS}/stdin"
  n="$(wc -l <"${CALLS}" | tr -d ' ')"
  printf 'call\n' >>"${CALLS}"
  if [[ "${n}" -lt 2 ]]; then
    return 255
  fi
  return 0
}

export IHP_DONE_TIMEOUT_SECONDS=30
export IHP_DONE_RETRY_SECONDS=0
host_wait_until_ihp_done "${SCRIPT}" platform \
  || fail "should succeed after SSH 255 retries"
calls="$(wc -l <"${CALLS}" | tr -d ' ')"
[[ "${calls}" -eq 3 ]] || fail "expected 3 host_ssh attempts, got ${calls}"
pass "retries SSH exit 255 until success"

grep -q 'host_volume_mount_root' "${STUBS}/stdin" \
  || fail "stdin should prepend host-volume-paths-host.sh; got: $(head -c 200 "${STUBS}/stdin")"
grep -q '#!/bin/true' "${STUBS}/stdin" \
  || fail "stdin should include wait script after lib"
pass "bash -s stdin prepends Host Volume path helpers"

: >"${CALLS}"
host_ssh() {
  cat >/dev/null
  printf 'call\n' >>"${CALLS}"
  return 1
}
if host_wait_until_ihp_done "${SCRIPT}" platform; then
  fail "should fail closed on non-255 remote failure"
fi
calls="$(wc -l <"${CALLS}" | tr -d ' ')"
[[ "${calls}" -eq 1 ]] || fail "expected single attempt on exit 1, got ${calls}"
pass "does not retry non-255 failures"

# Missing sibling lib fails closed before SSH.
BARE="${STUBS}/bare-wait.sh"
printf '#!/bin/true\n' >"${BARE}"
if host_wait_until_ihp_done "${BARE}" platform >/dev/null 2>&1; then
  fail "should fail when host-volume-paths-host.sh is missing"
fi
pass "fails closed when Host Volume path lib is missing"

echo "All host_wait_until_ihp_done checks passed."
