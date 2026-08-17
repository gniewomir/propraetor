#!/usr/bin/env bash
# Acceptance Test: Deploy is idempotent — second Deploy leaves Host Deployed.
# Suite baseline already Deployed before this case; re-run via root deploy.sh (#158 / ADR-0041).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

"${REPO_ROOT}/deploy.sh" --env "${PLATFORM_ENV:-test}"

# Empty Edge still answers on :80 after a second Deploy (no Environment Routes required).
expected=404
code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 "http://${IP}/" || true)"
if [[ "${code}" == "${expected}" ]]; then
  pass "second Deploy leaves empty Edge HTTP ${expected} on Host :80"
else
  fail "after second Deploy expected HTTP ${expected} on Host :80, got ${code}"
fi
