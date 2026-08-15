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

# Idle standing (no claimants file): every Persist client user is off.
cache_write_acl_file "${ADMIN_ENV}" || fail "ACL write idle with Persist clients"
grep -Eq '^user alpha off$' "${acl}" || fail "idle standing must disable alpha"
grep -Eq '^user gamma off$' "${acl}" || fail "idle standing must disable gamma"
grep -E '^user (alpha|gamma) on ' "${acl}" >/dev/null \
  && fail "idle standing must not leave Workload users enabled"
pass "idle standing disables Persist client ACL users"

echo "All cache-admin-env-host offline tests passed."
