#!/usr/bin/env bash
# Offline tests: Cache Workload ACL whitelist / deny expectations (ADR-0055 / #223).
# Does not talk to Valkey; asserts template string + rewritten users.acl shape.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=cache-admin-env-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/cache-admin-env-host.sh"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cache-acl.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

DATA_ROOT="${TMP}/data"
USER_NAME=""
mkdir -p "${DATA_ROOT}/conf" "${DATA_ROOT}/admin"
printf 'CACHE_ADMIN_USER=cacheadmin\nCACHE_ADMIN_PASSWORD=s3cret\n' \
  >"${DATA_ROOT}/admin/environment"
ADMIN_ENV="${DATA_ROOT}/admin/environment"

# Expected whitelist: type categories + explicit keyspace verbs; never +@keyspace.
EXPECTED_CMDS='-@all +@string +@hash +@list +@set +@sortedset +ping +del +unlink +exists +type +expire +expireat +pexpire +pexpireat +ttl +pttl +persist +touch'
cmds="$(cache_workload_acl_commands)"
[[ "${cmds}" == "${EXPECTED_CMDS}" ]] \
  || fail "cache_workload_acl_commands mismatch (got: ${cmds})"
[[ "${cmds}" != *'+@keyspace'* ]] \
  || fail "whitelist must not include +@keyspace"
pass "Workload ACL command whitelist matches ADR-0055/spike"

printf 'alpha\nbeta\n' >"${TMP}/claimants"
cache_write_acl_file "${ADMIN_ENV}" "${TMP}/claimants" || fail "ACL write with two claimants"
acl="${DATA_ROOT}/conf/users.acl"

grep -Eq '^user default off$' "${acl}" || fail "ACL must disable default"
grep -Fx "user alpha on resetpass ~alpha:* resetchannels ${EXPECTED_CMDS}" "${acl}" \
  || fail "alpha ACL line must be cert-only + prefix + whitelist"
grep -Fx "user beta on resetpass ~beta:* resetchannels ${EXPECTED_CMDS}" "${acl}" \
  || fail "beta ACL line must be cert-only + prefix + whitelist"

# Denied walkers / dangerous commands must not appear as explicit + grants.
for denied in scan keys flushall flushdb select dbsize randomkey copy rename move config; do
  grep -Fi "+${denied}" "${acl}" >/dev/null \
    && fail "Workload ACL must not grant +${denied}"
done
grep -F '+@keyspace' "${acl}" >/dev/null \
  && fail "Workload ACL must not grant +@keyspace"
pass "ACL deny expectations: no keyspace walkers or +@keyspace"

# Allowed DX verbs present on claimant lines (fixed-string; + is literal).
alpha_line="$(grep -E '^user alpha ' "${acl}")"
for allowed in del unlink exists type expire expireat pexpire pexpireat ttl pttl persist touch ping; do
  printf '%s\n' "${alpha_line}" | grep -Fq "+${allowed}" \
    || fail "alpha ACL must whitelist +${allowed}"
done
pass "ACL whitelist includes explicit del/exists/expire/ttl-family"

# Intent stop / non-claim: Persist client without claimant → ACL user off (#224).
mkdir -p "${DATA_ROOT}/clients/alpha" "${DATA_ROOT}/clients/gamma"
printf 'CERT\n' >"${DATA_ROOT}/clients/alpha/client.crt"
printf 'CERT\n' >"${DATA_ROOT}/clients/gamma/client.crt"
printf 'alpha\n' >"${TMP}/claimants-one"
cache_write_acl_file "${ADMIN_ENV}" "${TMP}/claimants-one" || fail "ACL write with retained non-claimant"
grep -Fx "user alpha on resetpass ~alpha:* resetchannels ${EXPECTED_CMDS}" "${acl}" \
  || fail "claimant alpha must stay enabled"
grep -Eq '^user gamma off$' "${acl}" \
  || fail "non-claimant with Persist client must be ACL-disabled (off)"
grep -E '^user gamma on ' "${acl}" >/dev/null \
  && fail "non-claimant gamma must not be enabled"
pass "non-claimant Persist client is ACL user off"

# Idle empty-claimants converge (explicit claimants file): every Persist client off.
# Not a standing-restart side effect (#232) — standing uses cache_ensure_standing_acl.
: >"${TMP}/no-claimants"
cache_write_acl_file "${ADMIN_ENV}" "${TMP}/no-claimants" \
  || fail "ACL write with empty claimants file"
grep -Eq '^user alpha off$' "${acl}" || fail "empty-claimants converge must disable alpha"
grep -Eq '^user gamma off$' "${acl}" || fail "empty-claimants converge must disable gamma"
grep -E '^user (alpha|gamma) on ' "${acl}" >/dev/null \
  && fail "empty-claimants converge must not leave Workload users enabled"
pass "empty-claimants Declaration converge disables Persist client ACL users"

# Standing ACL: refresh admin, preserve Workload users (#232).
printf 'CACHE_ADMIN_USER=cacheadmin\nCACHE_ADMIN_PASSWORD=rotated\n' \
  >"${ADMIN_ENV}"
printf '%s\n' \
  'user default off' \
  'user cacheadmin on #deadbeef ~* &* +@all' \
  "user alpha on resetpass ~alpha:* resetchannels ${EXPECTED_CMDS}" \
  'user gamma off' \
  >"${acl}"
cache_ensure_standing_acl "${ADMIN_ENV}" || fail "standing ACL ensure"
grep -Eq '^user default off$' "${acl}" || fail "standing ACL must keep default off"
grep -Eq '^user cacheadmin on #' "${acl}" || fail "standing ACL must refresh admin"
grep -Fq "user alpha on resetpass ~alpha:* resetchannels ${EXPECTED_CMDS}" "${acl}" \
  || fail "standing ACL must preserve claimant alpha"
grep -Eq '^user gamma off$' "${acl}" || fail "standing ACL must preserve gamma off"
grep -Fq '#deadbeef' "${acl}" && fail "standing ACL must replace stale admin hash"
pass "standing ACL preserves Workload users while refreshing admin"

# Standing cold path: no prior ACL → default + admin only (no Persist client walk).
rm -f "${acl}"
cache_ensure_standing_acl "${ADMIN_ENV}" || fail "standing ACL cold create"
grep -Eq '^user default off$' "${acl}" || fail "cold standing ACL must disable default"
grep -Eq '^user cacheadmin on #' "${acl}" || fail "cold standing ACL must emit admin"
grep -E '^user (alpha|gamma) ' "${acl}" >/dev/null \
  && fail "cold standing ACL must not emit Persist client users"
pass "cold standing ACL is admin-only baseline"

# Orphan drop Persist strip (#225 / #232): remove Workload line; keep peers + admin.
printf '%s\n' \
  'user default off' \
  'user cacheadmin on #abc ~* &* +@all' \
  "user alpha on resetpass ~alpha:* resetchannels ${EXPECTED_CMDS}" \
  "user orphan on resetpass ~orphan:* resetchannels ${EXPECTED_CMDS}" \
  >"${acl}"
cache_acl_file_remove_user orphan || fail "ACL file remove orphan"
grep -Eq '^user orphan ' "${acl}" && fail "orphan user line must be gone from Persist ACL"
grep -Fq "user alpha on resetpass ~alpha:* resetchannels ${EXPECTED_CMDS}" "${acl}" \
  || fail "peer claimant must remain after orphan strip"
grep -Eq '^user cacheadmin on #' "${acl}" || fail "admin must remain after orphan strip"
grep -Eq '^user default off$' "${acl}" || fail "default off must remain after orphan strip"
cache_acl_file_remove_user orphan || fail "ACL file remove must be idempotent when absent"
if cache_acl_file_remove_user default; then
  fail "must refuse to remove default"
fi
if cache_acl_file_remove_user cacheadmin; then
  fail "must refuse to remove admin"
fi
pass "orphan Persist ACL strip removes only the dropped basename"

echo "All cache-admin-env-host offline tests passed."
