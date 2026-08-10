#!/usr/bin/env bash
# Domain record Adopt through the Apply operator-command seam; no cloud access.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

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
  {"address":"module.durables.digitalocean_domain.this[\"enraged.dev\"]","mode":"managed","values":{"id":"enraged.dev"}},
  {"address":"module.durables.digitalocean_project_resources.durables","mode":"managed","values":{"id":"project-test-id"}}
]},{"address":"module.recreatables[0]","resources":[
  {"address":"module.recreatables[0].digitalocean_droplet.web","mode":"managed","values":{"id":4242}},
  {"address":"module.recreatables[0].digitalocean_reserved_ip_assignment.web","mode":"managed","values":{"ip_address":"203.0.113.10","droplet_id":4242}},
  {"address":"module.recreatables[0].digitalocean_project_resources.web_host","mode":"managed","values":{"id":"project-test-id"}},
  {"address":"module.recreatables[0].digitalocean_volume_attachment.web","mode":"managed","values":{"id":"attachment-test-id"}}
]}]}}}
JSON
    ;;
  import) exit 0 ;;
  plan) exit 2 ;;
  apply) exit 0 ;;
esac
EOF

cat >"${TMP_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
case "${url}" in
  *"/v2/domains?"*) printf '%s\n' '{"domains":[{"name":"enraged.dev"}]}' ;;
  *"/v2/domains/enraged.dev/records"*)
    printf '{"domain_records":[{"id":1001,"type":"A","name":"@","data":"%s"}]}\n' \
      "${RECORD_DATA:-203.0.113.10}"
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

: >"${TERRAFORM_CALLS}"
export RECORD_DATA=198.51.100.99
fail_out="$("${REPO_ROOT}/apply.sh" --yes --env test 2>&1)" && {
  echo "${fail_out}" >&2
  fail "Apply must fail closed when a declared Domain A record has a wrong endpoint"
}
grep -Fq "FAIL: Adopt: Domain enraged.dev record '@' exists with a wrong endpoint or conflicting type" <<<"${fail_out}" \
  || fail "wrong-endpoint Adopt failure unclear (output: ${fail_out})"
if grep -Eq '(^| )(plan |apply |import )' "${TERRAFORM_CALLS}"; then
  fail "Apply must not plan, apply, or import after a Domain record endpoint conflict"
fi
pass "Apply fails closed on a wrong Domain A record endpoint"

: >"${TERRAFORM_CALLS}"
export RECORD_DATA=203.0.113.10
"${REPO_ROOT}/apply.sh" --yes --env test >/dev/null

import_call='import -input=false module.durables.digitalocean_record.a["enraged.dev:@"] enraged.dev,1001'
grep -Fxq "${import_call}" "${TERRAFORM_CALLS}" \
  || fail "Apply must Adopt an exact declared Domain A record missing from State"

pass "Apply Adopts an exact declared Domain A record"
