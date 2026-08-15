#!/usr/bin/env bash
# Offline tests: shared Declaration claim lifecycle (#227).
# Stub adapters exercise gather → prepare → fulfill/unpublish → orphan through
# declaration_converge_claims / declaration_drop_absent_fulfillments.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=declaration-converge-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/declaration-converge-host.sh"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/declaration-converge.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

HOME_DIR="${TMP}/home"
UNIT_DIR="${TMP}/units"
WORKLOADS_ROOT="${TMP}/workloads"
DATA_ROOT="${TMP}/data"
USER_NAME=""
CLIENTS_DIR="${DATA_ROOT}/clients"

mkdir -p "${HOME_DIR}" "${UNIT_DIR}" "${WORKLOADS_ROOT}" "${CLIENTS_DIR}" \
  "${DATA_ROOT}/ca"

PREPARE_LOG="${TMP}/prepare.log"
FULFILL_LOG="${TMP}/fulfill.log"
UNPUBLISH_LOG="${TMP}/unpublish.log"
DROP_LOG="${TMP}/drop.log"
: >"${PREPARE_LOG}"
: >"${FULFILL_LOG}"
: >"${UNPUBLISH_LOG}"
: >"${DROP_LOG}"

stub_is_claimant() {
  local wl_dir="$1"
  local intent
  intent="$(workload_manifest_intent "${wl_dir}/manifest.json")" || return 1
  [[ "${intent}" == "run" ]] || {
    printf '0\n'
    return 0
  }
  if [[ -f "${wl_dir}/requires.json" ]] && grep -Fq '"want": true' "${wl_dir}/requires.json"; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

stub_validate_ok() { return 0; }

stub_validate_reject_colon() {
  local name="$1"
  if [[ "${name}" == *:* ]]; then
    echo "stub: basename '${name}' rejected" >&2
    return 1
  fi
  return 0
}

stub_prepare() {
  local sorted="$1"
  cat "${sorted}" >>"${PREPARE_LOG}"
}

stub_fulfill() {
  printf '%s\n' "$1" >>"${FULFILL_LOG}"
}

stub_unpublish() {
  printf '%s\n' "$1" >>"${UNPUBLISH_LOG}"
}

stub_binding_dir() {
  printf '%s/.config/platform/workloads/%s/stub\n' "${HOME_DIR}" "$1"
}

stub_drop() {
  printf '%s\n' "$1" >>"${DROP_LOG}"
}

write_wl() {
  local name="$1"
  local intent="$2"
  local want="$3"
  mkdir -p "${WORKLOADS_ROOT}/${name}/systemd"
  printf '%s\n' "{\"intent\":\"${intent}\",\"source\":\"internal\"}" \
    >"${WORKLOADS_ROOT}/${name}/manifest.json"
  printf '%s\n' "{\"want\": ${want}}" >"${WORKLOADS_ROOT}/${name}/requires.json"
  printf '[Container]\nImage=localhost/demo\n' \
    >"${WORKLOADS_ROOT}/${name}/systemd/${name}.container"
}

# --- converge: claim alpha, stop beta → fulfill alpha, unpublish beta ---
write_wl alpha run true
write_wl beta stop true
mkdir -p "$(stub_binding_dir beta)"
printf 'x\n' >"$(stub_binding_dir beta)/environment"

declaration_converge_claims \
  "${WORKLOADS_ROOT}" \
  "Stub" \
  "reserved" \
  stub_is_claimant \
  stub_validate_ok \
  stub_prepare \
  stub_fulfill \
  stub_unpublish \
  stub_binding_dir \
  || fail "converge should succeed"

grep -Fxq alpha "${PREPARE_LOG}" || fail "prepare must see claimant alpha"
grep -Fxq alpha "${FULFILL_LOG}" || fail "fulfill must run for alpha"
grep -Fxq beta "${UNPUBLISH_LOG}" || fail "unpublish must run for non-claimant beta"
grep -Fxq beta "${FULFILL_LOG}" && fail "stop Workload must not fulfill"
pass "converge gathers claimants, prepares, fulfills, unpublishes non-claimants"

# --- reserved basename fails closed ---
write_wl reserved run true
if declaration_converge_claims \
  "${WORKLOADS_ROOT}" \
  "Stub" \
  "reserved" \
  stub_is_claimant \
  stub_validate_ok \
  stub_prepare \
  stub_fulfill \
  stub_unpublish \
  stub_binding_dir >/dev/null 2>&1; then
  fail "reserved basename must fail closed"
fi
rm -rf "${WORKLOADS_ROOT}/reserved"
pass "reserved basename fails closed"

# --- validate basename hook fails closed ---
write_wl 'bad:name' run true
if declaration_converge_claims \
  "${WORKLOADS_ROOT}" \
  "Stub" \
  "reserved" \
  stub_is_claimant \
  stub_validate_reject_colon \
  stub_prepare \
  stub_fulfill \
  stub_unpublish \
  stub_binding_dir >/dev/null 2>&1; then
  fail "unsafe basename must fail closed via validate hook"
fi
rm -rf "${WORKLOADS_ROOT}/bad:name"
pass "validate-basename hook fails closed"

# --- absent client selection + orphan drop ---
mkdir -p "${CLIENTS_DIR}/alpha" "${CLIENTS_DIR}/gone"
printf 'x\n' >"${CLIENTS_DIR}/alpha/client.crt"
printf 'x\n' >"${CLIENTS_DIR}/gone/client.crt"
got="$(declaration_absent_client_basenames "${CLIENTS_DIR}" "${WORKLOADS_ROOT}" | paste -sd, -)"
[[ "${got}" == "gone" ]] || fail "want only gone selected, got '${got}'"

: >"${DROP_LOG}"
declaration_drop_absent_fulfillments \
  "${WORKLOADS_ROOT}" \
  "${CLIENTS_DIR}" \
  stub_drop \
  || fail "drop absent should succeed"
grep -Fxq gone "${DROP_LOG}" || fail "orphan drop must invoke drop for gone"
grep -Fxq alpha "${DROP_LOG}" && fail "SoT-present must not orphan-drop"
pass "orphan select + drop runs through shared seam"

# --- mTLS publish/unpublish projection ---
printf 'CA\n' >"${DATA_ROOT}/ca/ca.crt"
mkdir -p "${DATA_ROOT}/clients/gamma"
printf 'CERT\n' >"${DATA_ROOT}/clients/gamma/client.crt"
printf 'KEY\n' >"${DATA_ROOT}/clients/gamma/client.key"
mkdir -p "${WORKLOADS_ROOT}/gamma/systemd"
printf '[Container]\nImage=localhost/demo\n' \
  >"${WORKLOADS_ROOT}/gamma/systemd/gamma.container"

_stub_write_env() {
  local env_path="$1" wl_name="$2" mount_root="$3"
  cat >"${env_path}" <<EOF
STUB_HOST=stub
STUB_USER=${wl_name}
STUB_CA=${mount_root}/ca.crt
EOF
  chmod 0600 "${env_path}"
}

declaration_publish_mtls_binding \
  gamma stub 50-platform-stub.conf /etc/platform-stub _stub_write_env \
  || fail "publish should succeed"
binding="$(declaration_binding_dir gamma stub)"
[[ -f "${binding}/environment" ]] || fail "expected published environment"
grep -Fx 'STUB_HOST=stub' "${binding}/environment" >/dev/null \
  || fail "env writer must populate EnvironmentFile"
dropin="$(declaration_dropin_path gamma.container 50-platform-stub.conf)"
[[ -f "${dropin}" ]] || fail "expected Setup-owned drop-in"

declaration_unpublish_mtls_binding gamma stub 50-platform-stub.conf \
  || fail "unpublish should succeed"
[[ ! -e "${binding}" ]] || fail "binding dir must clear"
[[ ! -e "${dropin}" ]] || fail "drop-in must clear"
[[ -f "${DATA_ROOT}/clients/gamma/client.crt" ]] \
  || fail "durable client must remain after unpublish"
pass "shared mTLS publish/unpublish projection"

echo "All declaration-converge-host offline tests passed."
