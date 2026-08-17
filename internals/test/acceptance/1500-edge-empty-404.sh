#!/usr/bin/env bash
# Acceptance Test: empty Edge returns HTTP 404 on Host :80
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip

expected=404
if ! actual="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 "http://${IP}/")"; then
  fail "HTTP GET http://${IP}/ failed (Edge not reachable on :80?)"
fi

if [[ "${actual}" == "${expected}" ]]; then
  pass "empty Edge returns HTTP ${expected} on Host :80"
else
  fail "empty Edge on Host :80: expected HTTP ${expected}, got '${actual}'"
fi
