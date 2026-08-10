#!/usr/bin/env bash
# Durable Adopt through the Park operator-command seam; no cloud access.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# shellcheck source=unit_environments_root_fixture.sh
source "$(cd "$(dirname "$0")" && pwd)/unit_environments_root_fixture.sh"

mkdir -p "${TMP_DIR}/bin"
cat >"${TMP_DIR}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${TERRAFORM_CALLS}"
case "${1-}" in
  workspace) exit 0 ;;
  show) printf '%s\n' '{"values":{"root_module":{}}}' ;;
  import) exit 0 ;;
  plan) exit 0 ;;
  state) exit 0 ;;
esac
EOF

cat >"${TMP_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
case "${url}" in
  *"/v2/droplets?"*)
    if [[ "${PROVIDER_HOST_PRESENT:-false}" == true ]]; then
      printf '%s\n' '{"droplets":[{"id":4242,"name":"propraetor-test-web"}]}'
    else
      printf '%s\n' '{"droplets":[]}'
    fi
    ;;
  *"/v2/projects?"*)
    printf '%s\n' '{"projects":[{"id":"project-test-id","name":"propraetor-test"}]}'
    ;;
  *"/v2/volumes?"*)
    printf '%s\n' '{"volumes":[{"id":"volume-test-id","name":"propraetor-test-web-data","region":{"slug":"fra1"}}]}'
    ;;
  *"/v2/domains?"*)
    printf '%s\n' '{"domains":[{"name":"unit.example","ttl":1800,"zone_file":""}]}'
    ;;
  *)
    echo "unexpected provider request: ${url}" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${TMP_DIR}/bin/terraform" "${TMP_DIR}/bin/curl"

export PATH="${TMP_DIR}/bin:${PATH}"
export TERRAFORM_CALLS="${TMP_DIR}/terraform.calls"
export DIGITALOCEAN_TOKEN="test-token"
KEYS_DIR="${TMP_DIR}/operator-keys"
mkdir -p "${KEYS_DIR}"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey test@propraetor\n' >"${KEYS_DIR}/id.pub"
printf 'PRIVATE\n' >"${KEYS_DIR}/id"
chmod 600 "${KEYS_DIR}/id" "${KEYS_DIR}/id.pub"
export PROPRAETOR_PUBLIC_KEY_PATH="${KEYS_DIR}/id.pub"
export PROPRAETOR_PRIVATE_KEY_PATH="${KEYS_DIR}/id"

unit_environments_root_fixture

"${REPO_ROOT}/park.sh" --env test >/dev/null

import_call='import -input=false module.durables.digitalocean_project.propraetor project-test-id'
grep -Fxq "${import_call}" "${TERRAFORM_CALLS}" \
  || fail "Park must Adopt the exact Environment Cloud Project missing from State"

volume_import_call='import -input=false module.durables.digitalocean_volume.web volume-test-id'
grep -Fxq "${volume_import_call}" "${TERRAFORM_CALLS}" \
  || fail "Park must Adopt the exact Environment Host Volume missing from State"

domain_import_call='import -input=false module.durables.digitalocean_domain.this["unit.example"] unit.example'
grep -Fxq "${domain_import_call}" "${TERRAFORM_CALLS}" \
  || fail "Park must Adopt a Domain declared by exact FQDN and missing from State"

import_line="$(grep -nFx "${import_call}" "${TERRAFORM_CALLS}" | cut -d: -f1)"
plan_line="$(grep -nFx "plan -detailed-exitcode -input=false -var=recreatables_present=false" "${TERRAFORM_CALLS}" | cut -d: -f1)"
[[ "${import_line}" -lt "${plan_line}" ]] \
  || fail "Park must Adopt before its Terraform plan"

pass "Park Adopts exact Durables before planning"

: >"${TERRAFORM_CALLS}"
"${REPO_ROOT}/teardown.sh" --env test >/dev/null

grep -Fxq "${import_call}" "${TERRAFORM_CALLS}" \
  || fail "Teardown must Adopt exact Durables missing from State"
import_line="$(grep -nFx "${import_call}" "${TERRAFORM_CALLS}" | cut -d: -f1)"
state_line="$(grep -nFx "state list" "${TERRAFORM_CALLS}" | cut -d: -f1)"
[[ "${import_line}" -lt "${state_line}" ]] \
  || fail "Teardown must Adopt before checking whether State is empty"

pass "Teardown Adopts exact Durables before its destroy plan"

: >"${TERRAFORM_CALLS}"
export PROVIDER_HOST_PRESENT=true
if "${REPO_ROOT}/apply.sh" --yes --env test >/dev/null 2>&1; then
  fail "Apply must fail closed on an unbound provider Host"
fi
if grep -Eq '^(import|plan|apply) ' "${TERRAFORM_CALLS}"; then
  fail "Apply must not mutate State or provider after detecting an unbound Host"
fi

pass "Apply fails closed on forbidden Host-by-name Adopt"
