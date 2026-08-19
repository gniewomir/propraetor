#!/usr/bin/env bash
# Unit tests: Environment-scoped Identity resource / aud mapping (ADR-0057 / #253).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=identity-resource.sh
source "${REPO_ROOT}/internals/lib/identity/identity-resource.sh"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ "$(identity_resource_aud_for_slug test)" == "propreator:test" ]] \
  || fail "test slug aud"
[[ "$(identity_resource_aud_for_slug prod)" == "propreator:prod" ]] \
  || fail "prod slug aud"
[[ "$(identity_resource_api_display_name_for_slug test)" == "Propraetor test" ]] \
  || fail "display name"

if identity_resource_aud_for_slug 'Bad Slug' >/dev/null 2>&1; then
  fail "invalid slug must fail closed"
fi
pass "invalid slug rejected"

echo "All identity-resource offline tests passed."
