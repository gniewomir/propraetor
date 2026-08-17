#!/usr/bin/env bash
# Acceptance Test: outbound HTTPS from Host
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session

if host_ssh "curl -fsS -o /dev/null -w '%{http_code}' --connect-timeout 10 https://example.com" 2>/dev/null | grep -Eq '^[23][0-9][0-9]$'; then
  pass "outbound HTTPS from Host"
else
  fail "outbound HTTPS from Host failed"
fi
