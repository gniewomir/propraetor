#!/usr/bin/env bash
# Stack lifecycle operator-command seam. Uses a recording Terraform adapter; no cloud access.
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
  show)
    cat <<'JSON'
{"values":{"root_module":{"child_modules":[{"address":"module.durables","resources":[
  {"address":"module.durables.digitalocean_project.propraetor","mode":"managed","values":{"id":"project-test-id"}},
  {"address":"module.durables.digitalocean_volume.web","mode":"managed","values":{"id":"volume-test-id"}},
  {"address":"module.durables.digitalocean_reserved_ip.web","mode":"managed","values":{"ip_address":"203.0.113.10"}},
  {"address":"module.durables.digitalocean_domain.this[\"unit.example\"]","mode":"managed","values":{"id":"unit.example"}},
  {"address":"module.durables.digitalocean_record.a[\"unit.example:@\"]","mode":"managed","values":{"id":"1001"}},
  {"address":"module.durables.digitalocean_record.a[\"unit.example:www\"]","mode":"managed","values":{"id":"1002"}},
  {"address":"module.durables.digitalocean_record.a[\"unit.example:api\"]","mode":"managed","values":{"id":"1003"}},
  {"address":"module.durables.digitalocean_record.a[\"unit.example:test-acme\"]","mode":"managed","values":{"id":"1004"}},
  {"address":"module.durables.digitalocean_project_resources.durables","mode":"managed","values":{"id":"project-test-id"}}
]},{"address":"module.recreatables[0]","resources":[
  {"address":"module.recreatables[0].digitalocean_droplet.web","mode":"managed","values":{"id":4242}},
  {"address":"module.recreatables[0].digitalocean_reserved_ip_assignment.web","mode":"managed","values":{"ip_address":"203.0.113.10","droplet_id":4242}},
  {"address":"module.recreatables[0].digitalocean_project_resources.web_host","mode":"managed","values":{"id":"project-test-id"}},
  {"address":"module.recreatables[0].digitalocean_volume_attachment.web","mode":"managed","values":{"id":"attachment-test-id"}}
]}]}}}
JSON
    ;;
  plan) exit 2 ;;
  apply) exit 0 ;;
  state)
    printf '%s\n' "digitalocean_droplet.web"
    exit 0
    ;;
  destroy) exit 0 ;;
esac
exit 0
EOF
chmod +x "${TMP_DIR}/bin/terraform"

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

printf 'park\n' | "${REPO_ROOT}/park.sh" --env test >/dev/null

grep -Fxq \
  "plan -detailed-exitcode -input=false -var=recreatables_present=false" \
  "${TERRAFORM_CALLS}" \
  || fail "Park must plan complete Recreatable absence"
grep -Fxq \
  "apply -input=false -auto-approve -var=recreatables_present=false" \
  "${TERRAFORM_CALLS}" \
  || fail "Park must apply complete Recreatable absence"

if grep -Eq -- '(^| )(-target=|state |destroy($| ))' "${TERRAFORM_CALLS}"; then
  fail "Park must not use targets, raw terraform state commands, or terraform destroy"
fi

pass "Park supplies non-sticky Recreatable absence to a complete Terraform plan"

: >"${TERRAFORM_CALLS}"
TF_VAR_recreatables_present=false "${REPO_ROOT}/apply.sh" --yes --env test >/dev/null

grep -Fxq \
  "plan -detailed-exitcode -input=false -var=recreatables_present=true" \
  "${TERRAFORM_CALLS}" \
  || fail "Apply must plan complete Recreatable presence"
grep -Fxq \
  "apply -input=false -auto-approve -var=recreatables_present=true" \
  "${TERRAFORM_CALLS}" \
  || fail "Apply must explicitly request Recreatable presence"

pass "Apply overrides ambient variables with Recreatable presence"

: >"${TERRAFORM_CALLS}"
TF_VAR_recreatables_present=false "${REPO_ROOT}/apply.sh" --env test >/dev/null

grep -Fxq \
  "plan -detailed-exitcode -input=false -var=recreatables_present=true" \
  "${TERRAFORM_CALLS}" \
  || fail "interactive Apply must plan complete Recreatable presence"
grep -Fxq \
  "apply -var=recreatables_present=true" \
  "${TERRAFORM_CALLS}" \
  || fail "interactive Apply must explicitly request Recreatable presence"

pass "interactive Apply requests Recreatable presence"

: >"${TERRAFORM_CALLS}"
cat >"${TMP_DIR}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${TERRAFORM_CALLS}"
case "${1-}" in
  workspace) exit 0 ;;
  show)
    cat <<'JSON'
{"values":{"root_module":{"child_modules":[{"address":"module.durables","resources":[
  {"address":"module.durables.digitalocean_project.propraetor","mode":"managed","values":{"id":"project-test-id"}},
  {"address":"module.durables.digitalocean_volume.web","mode":"managed","values":{"id":"volume-test-id"}},
  {"address":"module.durables.digitalocean_reserved_ip.web","mode":"managed","values":{"ip_address":"203.0.113.10"}},
  {"address":"module.durables.digitalocean_domain.this[\"unit.example\"]","mode":"managed","values":{"id":"unit.example"}},
  {"address":"module.durables.digitalocean_record.a[\"unit.example:@\"]","mode":"managed","values":{"id":"1001"}},
  {"address":"module.durables.digitalocean_record.a[\"unit.example:www\"]","mode":"managed","values":{"id":"1002"}},
  {"address":"module.durables.digitalocean_record.a[\"unit.example:api\"]","mode":"managed","values":{"id":"1003"}},
  {"address":"module.durables.digitalocean_record.a[\"unit.example:test-acme\"]","mode":"managed","values":{"id":"1004"}},
  {"address":"module.durables.digitalocean_project_resources.durables","mode":"managed","values":{"id":"project-test-id"}}
]},{"address":"module.recreatables[0]","resources":[
  {"address":"module.recreatables[0].digitalocean_droplet.web","mode":"managed","values":{"id":4242}},
  {"address":"module.recreatables[0].digitalocean_reserved_ip_assignment.web","mode":"managed","values":{"ip_address":"203.0.113.10","droplet_id":4242}},
  {"address":"module.recreatables[0].digitalocean_project_resources.web_host","mode":"managed","values":{"id":"project-test-id"}},
  {"address":"module.recreatables[0].digitalocean_volume_attachment.web","mode":"managed","values":{"id":"attachment-test-id"}}
]}]}}}
JSON
    ;;
  plan) exit 0 ;;
  apply) exit 0 ;;
esac
exit 0
EOF
chmod +x "${TMP_DIR}/bin/terraform"

cat >"${TMP_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
case "${url}" in
  *"/v2/droplets?"*) printf '%s\n' '{"droplets":[{"id":4242,"name":"propraetor-test-web"}]}' ;;
  *"/v2/projects?"*) printf '%s\n' '{"projects":[{"id":"project-test-id","name":"propraetor-test"}]}' ;;
  *"/v2/projects/project-test-id/resources"*)
    printf '%s\n' '{"resources":[
      {"urn":"do:droplet:4242"},
      {"urn":"do:volume:volume-test-id"},
      {"urn":"do:reservedip:203.0.113.10"},
      {"urn":"do:domain:unit.example"}
    ]}'
    ;;
  *"/v2/volumes?"*) printf '%s\n' '{"volumes":[{"id":"volume-test-id","name":"propraetor-test-web-data","region":{"slug":"fra1"},"droplet_ids":[4242]}]}' ;;
  *"/v2/volumes/volume-test-id") printf '%s\n' '{"volume":{"id":"volume-test-id","droplet_ids":[4242]}}' ;;
  *"/v2/domains?"*) printf '%s\n' '{"domains":[{"name":"unit.example"}]}' ;;
  *"/v2/domains/unit.example/records"*)
    printf '%s\n' '{"domain_records":[
      {"id":1001,"type":"A","name":"@","data":"203.0.113.10"},
      {"id":1002,"type":"A","name":"www","data":"203.0.113.10"},
      {"id":1003,"type":"A","name":"api","data":"203.0.113.10"},
      {"id":1004,"type":"A","name":"test-acme","data":"203.0.113.10"}
    ]}'
    ;;
  *"/v2/reserved_ips/203.0.113.10")
    printf '%s\n' '{"reserved_ip":{"ip":"203.0.113.10","droplet":{"id":4242}}}'
    ;;
  *) echo "unexpected provider request: ${url}" >&2; exit 1 ;;
esac
EOF
chmod +x "${TMP_DIR}/bin/curl"

out="$(TF_VAR_recreatables_present=false "${REPO_ROOT}/apply.sh" --yes --env test)"
echo "${out}" | grep -Fq "Already Applied" \
  || fail "Apply must report Already Applied when the presence plan is empty"
if grep -Eq '(^| )apply( |$)' "${TERRAFORM_CALLS}"; then
  fail "Apply must not apply when the presence plan is empty"
fi

pass "Apply short-circuits on an empty presence plan"
