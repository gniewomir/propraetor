#!/usr/bin/env bash
# Unit tests: Cache operator console helpers (ADR-0055 / #226).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=cache-console.sh
source "${REPO_ROOT}/internals/lib/cache/cache-console.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- local port: integer in TCP range ---
port="$(cache_console_local_port)" || fail "local_port should succeed"
[[ "${port}" =~ ^[0-9]+$ ]] || fail "local_port want integer, got '${port}'"
[[ "${port}" -ge 1 && "${port}" -le 65535 ]] || fail "local_port out of range: ${port}"
pass "local_port returns a TCP port"

# --- cli base args: fixed TLS dial shape ---
got="$(cache_console_cli_base_args 16379 /tmp/ca.crt /tmp/c.crt /tmp/c.key)" \
  || fail "cli_base_args should succeed"
expected="$(printf '%s\n' \
  --tls \
  -h 127.0.0.1 \
  -p 16379 \
  --sni cache \
  --cacert /tmp/ca.crt \
  --cert /tmp/c.crt \
  --key /tmp/c.key)"
[[ "${got}" == "${expected}" ]] || fail "cli_base_args mismatch: got '${got}'"
pass "cli_base_args shape (tls, loopback, sni cache, material paths)"

if cache_console_cli_base_args notaport /tmp/ca.crt /tmp/c.crt /tmp/c.key \
  >/dev/null 2>&1; then
  fail "non-numeric port must fail closed"
fi
pass "cli_base_args rejects non-numeric port"

if cache_console_cli_base_args 0 /tmp/ca.crt /tmp/c.crt /tmp/c.key \
  >/dev/null 2>&1; then
  fail "port 0 must fail closed"
fi
pass "cli_base_args rejects port 0"

if cache_console_cli_base_args 6379 "" /tmp/c.crt /tmp/c.key \
  >/dev/null 2>&1; then
  fail "empty CA path must fail closed"
fi
pass "cli_base_args rejects empty CA path"

echo "All cache-console unit tests passed."
