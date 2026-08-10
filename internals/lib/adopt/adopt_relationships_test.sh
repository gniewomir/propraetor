#!/usr/bin/env bash
# Provider-native relationship Adopt through the Apply seam; no cloud access.
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
  {"address":"module.durables.digitalocean_volume.web","mode":"managed","values":{"id":"volume-test-id","urn":"do:volume:volume-test-id"}},
  {"address":"module.durables.digitalocean_reserved_ip.web","mode":"managed","values":{"ip_address":"203.0.113.10","urn":"do:reservedip:203.0.113.10"}},
  {"address":"module.durables.digitalocean_domain.this[\"unit.example\"]","mode":"managed","values":{"id":"unit.example","urn":"do:domain:unit.example"}},
  {"address":"module.durables.digitalocean_record.a[\"unit.example:@\"]","mode":"managed","values":{"id":"1001"}},
  {"address":"module.durables.digitalocean_record.a[\"unit.example:www\"]","mode":"managed","values":{"id":"1002"}},
  {"address":"module.durables.digitalocean_record.a[\"unit.example:api\"]","mode":"managed","values":{"id":"1003"}},
  {"address":"module.durables.digitalocean_record.a[\"unit.example:test-acme\"]","mode":"managed","values":{"id":"1004"}},
  {"address":"module.durables.digitalocean_project_resources.durables","mode":"managed","values":{"id":"project-test-id"}}
]},{"address":"module.recreatables[0]","resources":[
  {"address":"module.recreatables[0].digitalocean_droplet.web","mode":"managed","values":{"id":4242}},
  {"address":"module.recreatables[0].digitalocean_reserved_ip_assignment.web","mode":"managed","values":{"ip_address":"203.0.113.10","droplet_id":4242}}
]}]}}}
JSON
    ;;
  plan) exit 2 ;;
  apply) exit 0 ;;
esac
EOF

cat >"${TMP_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
case "${url}" in
  *"/v2/projects/project-test-id/resources"*)
    if [[ "${HOST_PROJECT_WRONG:-false}" == true ]]; then
      printf '%s\n' '{"resources":[
        {"urn":"do:volume:volume-test-id"},
        {"urn":"do:reservedip:203.0.113.10"},
        {"urn":"do:domain:unit.example"}
      ]}'
    else
      printf '%s\n' '{"resources":[
        {"urn":"do:volume:volume-test-id"},
        {"urn":"do:reservedip:203.0.113.10"},
        {"urn":"do:domain:unit.example"},
        {"urn":"do:droplet:4242"}
      ]}'
    fi
    ;;
  *"/v2/projects/wrong-project-id/resources"*)
    printf '%s\n' '{"resources":[{"urn":"do:droplet:4242"}]}'
    ;;
  *"/v2/projects?"*)
    printf '%s\n' '{"projects":[
      {"id":"project-test-id","name":"propraetor-test","is_default":false},
      {"id":"wrong-project-id","name":"other","is_default":false}
    ]}'
    ;;
  *"/v2/volumes/volume-test-id")
    printf '{"volume":{"id":"volume-test-id","droplet_ids":[%s]}}\n' "${VOLUME_HOST_ID:-4242}"
    ;;
  *) echo "unexpected provider request: ${url}" >&2; exit 1 ;;
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

output="$("${REPO_ROOT}/apply.sh" --yes --env test)"

grep -Fq "Adopt: Host Cloud Project membership will bind during Apply" <<<"${output}" \
  || fail "Apply must recognize exact Host membership for provider-native binding"
grep -Fq "Adopt: Host Volume attachment will bind during Apply" <<<"${output}" \
  || fail "Apply must recognize exact volume attachment for provider-native binding"

if grep -Fq "import " "${TERRAFORM_CALLS}"; then
  fail "non-importable relationships must bind through the provider Create handler"
fi

pass "Apply recognizes exact provider-native relationship Adopt"

: >"${TERRAFORM_CALLS}"
export VOLUME_HOST_ID=9999
if "${REPO_ROOT}/apply.sh" --yes --env test >/dev/null 2>&1; then
  fail "Apply must fail closed when the Host Volume is attached to another Host"
fi
if grep -Eq '(^| )(plan |apply )' "${TERRAFORM_CALLS}"; then
  fail "Apply must not plan or apply after a Host Volume endpoint conflict"
fi

pass "Apply fails closed on a wrong Host Volume attachment endpoint"

: >"${TERRAFORM_CALLS}"
export VOLUME_HOST_ID=4242
export HOST_PROJECT_WRONG=true
if "${REPO_ROOT}/apply.sh" --yes --env test >/dev/null 2>&1; then
  fail "Apply must fail closed when Host membership points at another Cloud Project"
fi
if grep -Eq '(^| )(plan |apply )' "${TERRAFORM_CALLS}"; then
  fail "Apply must not plan or apply after a Cloud Project membership endpoint conflict"
fi

# Ownership-boundary membership fail-closed (#63 AC; prove existing).
pass "Apply fails closed on a wrong Cloud Project membership endpoint"
