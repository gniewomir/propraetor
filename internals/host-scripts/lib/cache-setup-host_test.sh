#!/usr/bin/env bash
# Offline contract: Cache Setup ready-wait + standing vs Declaration converge
# ordering (#232 / ADR-0055 / #221).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SETUP="${REPO_ROOT}/internals/host-scripts/lib/cache-setup-host.sh"
ADMIN="${REPO_ROOT}/internals/host-scripts/lib/cache-admin-env-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -f "${SETUP}" ]] || fail "missing ${SETUP}"
[[ -f "${ADMIN}" ]] || fail "missing ${ADMIN}"

grep -Fq 'ActiveState' "${SETUP}" \
  || fail "cache_wait_ready must observe cache-valkey ActiveState"
grep -Fq 'cache-valkey.service failed before ready' "${SETUP}" \
  || fail "cache_wait_ready must fail closed on ActiveState=failed"
grep -Fq 'NetworkAlias=cache' \
  "${REPO_ROOT}/internals/components/cache/systemd/cache.pod" \
  || fail "cache.pod must NetworkAlias=cache"
if grep -Eq '^PublishPort=' \
  "${REPO_ROOT}/internals/components/cache/systemd/cache.pod"; then
  fail "cache.pod must not PublishPort"
fi

# Named seams (#232).
grep -Eq '^cache_standing_ensure\(\)' "${SETUP}" \
  || fail "standing ensure must be named cache_standing_ensure"
grep -Eq '^cache_fulfill_declarations\(\)' \
  "${REPO_ROOT}/internals/host-scripts/lib/cache-fulfill-host.sh" \
  || fail "Declaration converge adapter must be named cache_fulfill_declarations"
grep -Eq '^cache_ensure_standing_acl\(\)' "${ADMIN}" \
  || fail "standing ACL seam must be named cache_ensure_standing_acl"

# Standing must not idle-rewrite ACL (no claimants-file-less cache_write_acl_file).
if grep -E 'cache_write_acl_file[[:space:]]+"\$\{ADMIN_ENV\}"[[:space:]]*$' "${SETUP}" >/dev/null; then
  fail "standing ensure must not call cache_write_acl_file without claimants"
fi
grep -Fq 'cache_ensure_standing_acl' "${SETUP}" \
  || fail "standing ensure must call cache_ensure_standing_acl"

# Ordering invariant: extract function bodies and assert call order.
pre_body="$(awk '/^cache_setup_pre_workloads\(\)/,/^}/' "${SETUP}")"
printf '%s\n' "${pre_body}" | grep -Fq 'cache_standing_ensure' \
  || fail "pre-workloads must call cache_standing_ensure"
printf '%s\n' "${pre_body}" | grep -Fq 'cache_fulfill_declarations' \
  || fail "pre-workloads must call Declaration converge"
standing_line="$(printf '%s\n' "${pre_body}" | grep -n 'cache_standing_ensure' | head -n1 | cut -d: -f1)"
fulfill_line="$(printf '%s\n' "${pre_body}" | grep -n 'cache_fulfill_declarations' | head -n1 | cut -d: -f1)"
[[ "${standing_line}" -lt "${fulfill_line}" ]] \
  || fail "pre-workloads must standing ensure before Declaration converge"

post_body="$(awk '/^cache_setup_post_workloads\(\)/,/^}/' "${SETUP}")"
printf '%s\n' "${post_body}" | grep -Fq 'cache_standing_ensure' \
  || fail "post-workloads must call cache_standing_ensure"
printf '%s\n' "${post_body}" | grep -Fq 'cache_drop_absent_fulfillments' \
  || fail "post-workloads must drop Orphan-absent fulfillments"
if printf '%s\n' "${post_body}" | grep -Fq 'cache_fulfill_declarations'; then
  fail "post-workloads must not re-fulfill solely to undo standing ensure"
fi
standing_post="$(printf '%s\n' "${post_body}" | grep -n 'cache_standing_ensure' | head -n1 | cut -d: -f1)"
drop_post="$(printf '%s\n' "${post_body}" | grep -n 'cache_drop_absent_fulfillments' | head -n1 | cut -d: -f1)"
[[ "${standing_post}" -lt "${drop_post}" ]] \
  || fail "post-workloads must standing ensure before Orphan drop"

pass "Cache standing vs Declaration converge ordering"

echo "All cache-setup-host offline tests passed."
