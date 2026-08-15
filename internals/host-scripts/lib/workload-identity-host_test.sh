#!/usr/bin/env bash
# Unit tests: Workload identity + reserved dial basenames (#233).
# Seam: workload_identity_require.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=workload-identity-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/workload-identity-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

workload_identity_require "web-api" || fail "valid basename must pass"
pass "valid basename accepted"

if workload_identity_require "database" 2>/dev/null; then
  fail "database dial basename must fail closed"
fi
pass "database reserved"

if workload_identity_require "cache" 2>/dev/null; then
  fail "cache dial basename must fail closed"
fi
pass "cache reserved"

if workload_identity_require "../x" 2>/dev/null; then
  fail "path segment with slash must fail closed"
fi
if workload_identity_require ".hidden" 2>/dev/null; then
  fail "hidden basename must fail closed"
fi
pass "invalid identity shapes refused"

# Operator and Host entrypoints must not inline the checks.
if grep -E 'basename .database. is reserved' \
  "${REPO_ROOT}/internals/ensure-workload.sh" \
  "${REPO_ROOT}/internals/host-scripts/ensure-workload-host.sh" \
  2>/dev/null; then
  fail "entrypoints must not duplicate reserved-basename checks"
fi
grep -Fq 'workload_identity_require' "${REPO_ROOT}/internals/ensure-workload.sh" \
  || fail "operator Setup must call workload_identity_require"
grep -Fq 'workload_setup_apply' \
  "${REPO_ROOT}/internals/host-scripts/ensure-workload-host.sh" \
  || fail "Host entry must call workload_setup_apply"
pass "identity not duplicated in entrypoints"

echo "All workload identity checks passed."
