#!/usr/bin/env bash
# Unit tests: ensure-workload(s) entrypoint hard cut and batch discovery (#157 / #217).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/environment/environment-workloads.sh
source "${REPO_ROOT}/internals/lib/environment/environment-workloads.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

INTERNALS="${REPO_ROOT}/internals"
HOST_SCRIPTS="${REPO_ROOT}/internals/host-scripts"

for gone in \
  "${INTERNALS}/workload-setup.sh" \
  "${INTERNALS}/purge-workloads.sh" \
  "${INTERNALS}/purge-trash.sh" \
  "${HOST_SCRIPTS}/workload-setup-host.sh" \
  "${HOST_SCRIPTS}/purge-workloads-host.sh" \
  "${HOST_SCRIPTS}/purge-trash-host.sh"; do
  [[ ! -e "${gone}" ]] || fail "legacy path still present: ${gone}"
done
pass "legacy workload-setup / purge-workloads / purge-trash paths are gone"

for want in \
  "${INTERNALS}/ensure-workload.sh" \
  "${INTERNALS}/ensure-workloads.sh" \
  "${INTERNALS}/purge-orphans.sh" \
  "${HOST_SCRIPTS}/ensure-workload-host.sh" \
  "${HOST_SCRIPTS}/purge-orphans-host.sh"; do
  [[ -f "${want}" ]] || fail "missing ${want}"
done
pass "ensure-workload(s) and Orphan Reap entrypoints exist"

# Batch discovery uses the same Environment helper as Mirror (directory identity).
TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/ensure-workloads.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
ENV_DIR="${TMP}/env"
mkdir -p "${ENV_DIR}/keep-me" "${ENV_DIR}/also" "${ENV_DIR}/nope"
printf '{"intent":"run"}\n' >"${ENV_DIR}/keep-me/manifest.json"
printf '{"intent":"stop"}\n' >"${ENV_DIR}/also/manifest.json"
printf 'not a workload\n' >"${ENV_DIR}/domains.json"
printf 'x\n' >"${ENV_DIR}/nope/README.md"

got="$(environment_discover_workloads "${ENV_DIR}" | paste -sd, -)"
[[ "${got}" == "also,keep-me,nope" ]] || fail "batch discovery want also,keep-me,nope got '${got}'"
pass "ensure-workloads discovery set matches Environment Workload directories"

# ensure-workloads composes singular ensure-workload (script contract)
grep -Fq 'ensure-workload.sh' "${INTERNALS}/ensure-workloads.sh" \
  || fail "ensure-workloads must invoke ensure-workload.sh"
grep -Fq 'environment_discover_workloads' "${INTERNALS}/ensure-workloads.sh" \
  || fail "ensure-workloads must discover via environment_discover_workloads"
grep -Fq '</dev/null' "${INTERNALS}/ensure-workloads.sh" \
  || fail "ensure-workloads must close child stdin so discovery names are not stolen"
pass "ensure-workloads composes discovery + singular ensure-workload"

# Flat Host stage must ship every lib ensure-workload-host sources from HERE (#157 / ADR-0052 regress).
HOST_SH="${HOST_SCRIPTS}/ensure-workload-host.sh"
ENSURE_SH="${INTERNALS}/ensure-workload.sh"
while IFS= read -r lib; do
  [[ -n "${lib}" ]] || continue
  grep -Eq "cp \"\\\$\{[A-Z_]+\}\" \"\\\$\{STAGE\}/${lib}\"" "${ENSURE_SH}" \
    || grep -Fq "\"\${STAGE}/${lib}\"" "${ENSURE_SH}" \
    || fail "ensure-workload.sh must stage ${lib} (sourced by ensure-workload-host from HERE)"
done < <(grep -E '^\s*source "\$\{HERE\}/[^"]+\.sh"' "${HOST_SH}" \
  | sed -E 's/.*source "\$\{HERE\}\/([^"]+\.sh)".*/\1/')
pass "ensure-workload stages every HERE-sourced host lib"

# Offline batch loop: child that reads stdin must not drop remaining names
FAKE_BIN="${TMP}/fake-bin"
mkdir -p "${FAKE_BIN}"
cat >"${FAKE_BIN}/ensure-workload.sh" <<'EOF'
#!/usr/bin/env bash
# Consume stdin if present (simulates Host-facing helpers that read).
cat >/dev/null || true
printf 'ran:%s\n' "$1"
EOF
chmod +x "${FAKE_BIN}/ensure-workload.sh"

# shellcheck source=lib/cli.sh
source "${REPO_ROOT}/internals/lib/cli.sh"
# Minimal stand-in for the batch loop body
ran=0
names=""
while IFS= read -r wl_name; do
  [[ -n "${wl_name}" ]] || continue
  out="$("${FAKE_BIN}/ensure-workload.sh" "${wl_name}" </dev/null)"
  names="${names}${names:+,}${out}"
  ran=$((ran + 1))
done < <(environment_discover_workloads "${ENV_DIR}")
[[ "${ran}" -eq 3 ]] || fail "batch loop should visit 3 Workloads, got ${ran}"
[[ "${names}" == "ran:also,ran:keep-me,ran:nope" ]] || fail "batch order/names want ran:also,ran:keep-me,ran:nope got '${names}'"
pass "batch loop visits every discovered Workload without stdin steal"

echo "All ensure-workload(s) / Orphan Reap entrypoint checks passed."
