#!/usr/bin/env bash
# Unit tests: park.sh Environment known_hosts forget seams (ADR-0046).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARK="${REPO_ROOT}/park.sh"
TEARDOWN="${REPO_ROOT}/teardown.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -f "${PARK}" ]] || fail "missing ${PARK}"
[[ -x "${PARK}" ]] || fail "park.sh not executable"

grep -Fq 'internals/lib/ssh.sh' "${PARK}" || fail "park.sh must source lib/ssh.sh"
grep -Fq 'propraetor_ssh_forget_host' "${PARK}" || fail "park.sh must call propraetor_ssh_forget_host"
grep -Fq 'park_forget_host_keys' "${PARK}" || fail "park.sh must define park_forget_host_keys"

# Already-Parked early exit and post-apply path both invalidate TOFU.
already="$(
  awk '
    /Already Parked/ { in_block=1 }
    in_block && /park_forget_host_keys/ { print "already"; exit }
    in_block && /^[[:space:]]*exit 0/ { exit }
  ' "${PARK}"
)"
[[ "${already}" == "already" ]] || fail "park.sh must forget known_hosts on already-Parked exit"
pass "park.sh forgets known_hosts on already-Parked early exit"

after_apply="$(
  awk '
    /terraform apply/ { saw_apply=1; next }
    saw_apply && /park_forget_host_keys/ { print "after_apply"; exit }
  ' "${PARK}"
)"
[[ "${after_apply}" == "after_apply" ]] || fail "park.sh must forget known_hosts after terraform apply"
pass "park.sh forgets known_hosts after successful Park apply"

# Teardown alignment: full store reset (IP gone), not forget-only.
grep -Fq 'propraetor_ssh_known_hosts_reset' "${TEARDOWN}" \
  || fail "teardown.sh must reset Environment known_hosts store"
pass "teardown.sh resets Environment known_hosts store"

echo "All park known_hosts forget checks passed."
