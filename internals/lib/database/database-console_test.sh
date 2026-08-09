#!/usr/bin/env bash
# Unit tests: Database operator console helpers (ADR-0049 / #192).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=database-console.sh
source "${REPO_ROOT}/internals/lib/database/database-console.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- mode: empty / omitted → read ---
got="$(database_console_normalize_mode "")" || fail "empty mode should succeed"
[[ "${got}" == "read" ]] || fail "empty mode want read, got '${got}'"
pass "empty mode defaults to read"

got="$(database_console_normalize_mode "read")" || fail "read should succeed"
[[ "${got}" == "read" ]] || fail "read want read, got '${got}'"
pass "mode read"

got="$(database_console_normalize_mode "write")" || fail "write should succeed"
[[ "${got}" == "write" ]] || fail "write want write, got '${got}'"
pass "mode write"

if database_console_normalize_mode "admin" >/dev/null 2>&1; then
  fail "unknown mode must fail closed"
fi
pass "unknown mode fails closed"

if database_console_normalize_mode "READ" >/dev/null 2>&1; then
  fail "case-sensitive mode: READ must fail closed"
fi
pass "mode is case-sensitive"

# --- soft RO seatbelt (bypassable session default) ---
got="$(database_console_pgoptions "read")" || fail "read pgoptions"
[[ "${got}" == "-c default_transaction_read_only=on" ]] \
  || fail "read pgoptions want soft RO, got '${got}'"
pass "read sets soft default_transaction_read_only"

got="$(database_console_pgoptions "write")" || fail "write pgoptions"
[[ -z "${got}" ]] || fail "write pgoptions must be empty, got '${got}'"
pass "write omits soft RO"

if database_console_pgoptions "nope" >/dev/null 2>&1; then
  fail "pgoptions for unknown mode must fail closed"
fi
pass "pgoptions rejects unknown mode"

echo "All database-console unit tests passed."
