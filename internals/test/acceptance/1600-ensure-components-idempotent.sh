#!/usr/bin/env bash
# Acceptance Test: ensure-components is idempotent (second run; empty Edge still 404)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

"${REPO_ROOT}/internals/ensure-components.sh" post-workloads --env "${PLATFORM_ENV:-test}"

expected=404
if ! actual="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 "http://${IP}/")"; then
  fail "HTTP GET http://${IP}/ failed after re-ensure (Edge not reachable on :80?)"
fi

if [[ "${actual}" == "${expected}" ]]; then
  pass "ensure-components re-run leaves empty Edge HTTP ${expected} on Host :80"
else
  fail "after re-ensure empty Edge on Host :80: expected HTTP ${expected}, got '${actual}'"
fi
