#!/usr/bin/env bash
# Unit tests: Host Workload projection Persist contract (ADR-0054 / #228).
# Seam: workload_project_to_host — Persist preserve + empty create live here,
# not in dual Mirror/Setup harnesses.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=workload-project-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/workload-project-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/wl-project.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

write_internal_tree() {
  local tree="$1"
  mkdir -p "${tree}/systemd" "${tree}/www"
  printf '{}\n' >"${tree}/binding.json"
  # Internal Source: Environment is Artifact — do not list systemd in Provides
  # directories (filename merge would collide with the Environment bag).
  printf '{ "directories": { "www": "static" } }\n' >"${tree}/provides.json"
  printf '{ "database": false, "cache": false }\n' >"${tree}/requires.json"
  cat >"${tree}/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
  printf '[Container]\nImage=localhost/proj\n' >"${tree}/systemd/proj.container"
  printf 'content-v1\n' >"${tree}/www/index.html"
}

ENV_TREE="${TMP}/env-wl"
DEST="${TMP}/host-wl"
write_internal_tree "${ENV_TREE}"

# --- missing Persist is created empty ---
workload_project_to_host "${ENV_TREE}" "${DEST}" \
  || fail "project must succeed when Persist is absent"
[[ -d "${DEST}/persist" ]] || fail "missing Persist must be created empty"
[[ -z "$(find "${DEST}/persist" -mindepth 1 -print -quit)" ]] \
  || fail "auto-created Persist must be empty"
grep -Fxq 'content-v1' "${DEST}/www/index.html" \
  || fail "projection must land Provides directories"
[[ -f "${DEST}/systemd/proj.container" ]] \
  || fail "projection must land systemd bag"
pass "workload_project_to_host creates empty Persist when missing"

# --- existing Persist bytes survive replace ---
mkdir -p "${DEST}/persist/nested"
printf 'durable\n' >"${DEST}/persist/nested/state.bin"
printf 'stale-sot\n' >"${DEST}/stale.txt"
printf 'content-v2\n' >"${ENV_TREE}/www/index.html"

workload_project_to_host "${ENV_TREE}" "${DEST}" \
  || fail "re-project must succeed with existing Persist"
grep -Fxq 'content-v2' "${DEST}/www/index.html" \
  || fail "SoT must update on re-project"
[[ ! -e "${DEST}/stale.txt" ]] || fail "non-Persist stale must be pruned"
grep -Fxq 'durable' "${DEST}/persist/nested/state.bin" \
  || fail "Persist bytes must survive re-project"
[[ -d "${DEST}/persist" ]] || fail "Persist directory must remain"
pass "workload_project_to_host preserves Persist on replace"

# --- Environment persist/ fails closed (materialize refuse via projection) ---
BAD="${TMP}/bad-env"
write_internal_tree "${BAD}"
mkdir -p "${BAD}/persist"
printf 'nope\n' >"${BAD}/persist/x"
if workload_project_to_host "${BAD}" "${TMP}/bad-dest" 2>"${TMP}/bad-err"; then
  fail "Environment persist/ must fail closed through projection"
fi
grep -Eqi 'persist' "${TMP}/bad-err" \
  || fail "Environment persist rejection unclear: $(cat "${TMP}/bad-err")"
pass "workload_project_to_host refuses Environment persist/"

# --- Manifest-less bag still gets empty Persist ---
BAG="${TMP}/bag-env"
BAG_DEST="${TMP}/bag-dest"
mkdir -p "${BAG}/notes"
printf 'draft\n' >"${BAG}/notes/idea.md"
workload_project_to_host "${BAG}" "${BAG_DEST}" \
  || fail "Manifest-less bag project must succeed"
grep -Fxq 'draft' "${BAG_DEST}/notes/idea.md" \
  || fail "Manifest-less bag must project"
[[ -d "${BAG_DEST}/persist" ]] || fail "Manifest-less bag must get empty Persist"
pass "workload_project_to_host projects Manifest-less bag with empty Persist"

echo "All workload-project-host offline tests passed."
