#!/usr/bin/env bash
# Unit test: IHP user_data via production cloud-init/render module
# (ADR-0030 / ADR-0031 / ADR-0050).
# Asserts outcomes on the document Terraform delivers — not template/main.tf source shape.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
RENDER_MODULE="${REPO_ROOT}/internals/terraform/modules/recreatables/cloud-init/render"

# Known fixture inputs (independent of recreatables local.ssh_port twin).
SSH_PORT=9417
VOLUME_NAME="propraetor-test-web-data"
ROOT_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureRootKey propraetor-ihp-test"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

command -v terraform >/dev/null || fail "terraform not found"
command -v ruby >/dev/null || fail "ruby not found (YAML parse)"

[[ -d "${RENDER_MODULE}" ]] || fail "missing render module at ${RENDER_MODULE}"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/platform-ihp-ud.XXXXXX")"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

cat >"${WORKDIR}/main.tf" <<EOF
module "ihp_user_data" {
  source = "${RENDER_MODULE}"

  volume_name              = "${VOLUME_NAME}"
  ssh_port                 = ${SSH_PORT}
  host_root_ssh_public_key = "${ROOT_PUBKEY}"
}

output "user_data" {
  value = module.ihp_user_data.user_data
}
EOF

terraform -chdir="${WORKDIR}" init -backend=false >/dev/null
terraform -chdir="${WORKDIR}" apply -input=false -auto-approve >/dev/null
terraform -chdir="${WORKDIR}" output -raw user_data >"${WORKDIR}/user_data.yaml"

# First non-empty line of each content: | block must be indented (not column 0).
if awk '
  /^[[:space:]]*content:[[:space:]]*\|[[:space:]]*$/ { want=1; next }
  want && NF { if ($0 !~ /^[[:space:]]/) { exit 1 } want=0 }
' "${WORKDIR}/user_data.yaml"; then
  pass "literal-block content lines are indented"
else
  fail "a content: | block has an unindented first line (indent() first-line trap)"
fi

ruby -ryaml -e "YAML.load_file('${WORKDIR}/user_data.yaml')" \
  || fail "rendered user_data is not valid YAML"
pass "rendered user_data parses as YAML"

ruby -ryaml -e "
ssh_port = ${SSH_PORT}
volume_name = '${VOLUME_NAME}'
root_pubkey = '${ROOT_PUBKEY}'
d = YAML.load_file('${WORKDIR}/user_data.yaml')
files = d['write_files'] || []
by_path = files.map { |x| [x['path'], x] }.to_h

auth = by_path['/root/.ssh/authorized_keys']
abort('missing root authorized_keys') unless auth
abort('root authorized_keys missing pubkey') unless auth['content'].to_s.include?(root_pubkey)
abort('root authorized_keys wrong mode') unless auth['permissions'].to_s == '0600'

port = by_path['/etc/ssh/sshd_config.d/99-ssh-port.conf']
abort('missing Port drop-in') unless port
abort('Port drop-in wrong value') unless port['content'].to_s.include?(\"Port #{ssh_port}\")

script = by_path['/usr/local/lib/host-volume/ensure-host-volume-mount.sh']
abort('missing volume script') unless script
# Shebang must be at byte 0. A leading newline (indent+literal-block trap) makes
# systemd fail with Exec format error -> runcmd fails -> cloud-init status: error.
body = script['content'].to_s
abort('volume script must start with shebang (no leading newline)') unless body.start_with?('#!/usr/bin/env bash')

unit = by_path['/etc/systemd/system/host-volume.service']
abort('missing host-volume.service') unless unit
unit_text = unit['content'].to_s
abort('unit missing Restart=on-failure') unless unit_text.include?('Restart=on-failure')
abort('unit missing StartLimitIntervalSec=300') unless unit_text.include?('StartLimitIntervalSec=300')

abort('missing tmpfiles WantedBy recipe') unless by_path['/etc/tmpfiles.d/host-volume.conf']
abort('missing udev late-attach rule') unless by_path['/etc/udev/rules.d/99-host-volume.rules']

abort('missing power_state reboot') unless d.dig('power_state', 'mode') == 'reboot'

bootcmd_rows = d['bootcmd'] || []
bootcmd = bootcmd_rows.map { |x| Array(x).join(' ') }.join(\"\\n\")
abort('bootcmd must clear root password ageing (DO lastchg=0 breaks BatchMode SSH)') unless bootcmd.include?('chage -d -1 -M -1 root')
abort('bootcmd must lock root password') unless bootcmd.include?('passwd -l root')
# cloud-init schema (26.1+): bootcmd argv items must be strings. Bare YAML -1
# becomes Integer and fails validation -> degraded done / IHP wait exit 2.
chage = bootcmd_rows.find { |cmd| Array(cmd).include?('chage') }
abort('missing chage bootcmd row') unless chage
Array(chage).each do |arg|
  next if arg.is_a?(String)
  abort(\"bootcmd chage arg #{arg.inspect} must be String (cloud-init schema)\")
end

runcmd = (d['runcmd'] || []).map(&:to_s).join(\"\\n\")
abort('runcmd must not wait/mount Host Volume scsi device') if runcmd.include?('scsi-0DO_Volume')

# ADR-0050 Platform journal Substrate artifacts (issue #195).
journal = by_path['/etc/systemd/journald.conf.d/99-platform-journal.conf']
abort('missing journald Platform journal drop-in') unless journal
journal_text = journal['content'].to_s
abort('journald drop-in missing Storage=persistent') unless journal_text.include?('Storage=persistent')
abort('journald drop-in missing SystemMaxUse=200M') unless journal_text.include?('SystemMaxUse=200M')
abort('journald drop-in missing SystemKeepFree=') unless journal_text.match?(/SystemKeepFree=\\S+/)
abort('journald drop-in missing RuntimeMaxUse=') unless journal_text.match?(/RuntimeMaxUse=\\S+/)

containers = by_path['/home/platform/.config/containers/containers.conf']
abort('missing Platform User containers.conf') unless containers
abort('containers.conf wrong owner') unless containers['owner'].to_s == 'platform:platform'
containers_text = containers['content'].to_s
abort('containers.conf missing [containers]') unless containers_text.include?('[containers]')
abort('containers.conf missing journald log_driver pin') unless containers_text.match?(/log_driver\\s*=\\s*\"journald\"/)

abort('runcmd must restart systemd-journald so drop-in is live') unless runcmd.include?('systemctl restart systemd-journald')

doc_lines = File.readlines('${WORKDIR}/user_data.yaml')
active = doc_lines.reject { |l| l.match?(/^\\s*#/) }.join
# Capture contract is the Platform User pin — not per-Quadlet LogDriver= spray.
abort('user_data must not spray LogDriver= (containers.conf pin is the contract)') if active.include?('LogDriver=')
if active.match?(/sshd-socket-generator|ensure-ssh-listen|ssh\\.socket\\.d/)
  abort('must not mask generator or ship ssh.socket.d overrides')
end
" || fail "rendered user_data contract (ADR-0030 / ADR-0031 / ADR-0037 / ADR-0050)"
pass "rendered user_data matches IHP delivery contract"
