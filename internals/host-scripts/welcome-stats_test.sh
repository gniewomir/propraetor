#!/usr/bin/env bash
# Unit tests: welcome Host usage sampler (paths / math / atomic JSON write).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/environments/prod/welcome/scripts/welcome-stats.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -f "${SCRIPT}" ]] || fail "missing ${SCRIPT}"

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/welcome-stats.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/proc" "${TMP}/hv" "${TMP}/out"
# MemTotal 1000 kB, MemAvailable 250 kB → 75% used
printf 'MemTotal:       1000 kB\nMemAvailable:    250 kB\n' >"${TMP}/proc/meminfo"
# Two identical cpu samples (CPU_SAMPLE_SEC=0) → 0%
printf 'cpu  100 0 0 100 0 0 0 0 0 0\n' >"${TMP}/proc/stat"

# shellcheck source=../../environments/prod/welcome/scripts/welcome-stats.sh
source "${SCRIPT}"

export WELCOME_STATS_PROC="${TMP}/proc"
export WELCOME_STATS_HOST_VOLUME="${TMP}/hv"
export WELCOME_STATS_OUT_DIR="${TMP}/out"
export WELCOME_STATS_OUT_FILE="${TMP}/out/stats.json"
export WELCOME_STATS_CPU_SAMPLE_SEC=0

[[ "$(welcome_stats_mem_percent)" == "75" ]] || fail "mem percent expected 75"
pass "mem percent from MemTotal/MemAvailable"

[[ "$(welcome_stats_cpu_percent)" == "0" ]] || fail "cpu percent expected 0 on identical samples"
pass "cpu percent handles zero delta"

dd if=/dev/zero of="${TMP}/hv/pad" bs=1024 count=4 status=none 2>/dev/null || true
disk="$(welcome_stats_disk_percent)"
[[ "${disk}" =~ ^[0-9]+$ ]] || fail "disk percent not an integer: ${disk}"
[[ "${disk}" -ge 0 && "${disk}" -le 100 ]] || fail "disk percent out of range: ${disk}"
pass "disk percent is an integer 0–100"

welcome_stats_write_json 12 34 56
grep -Eq '"cpu_percent":12' "${TMP}/out/stats.json" || fail "cpu field missing"
grep -Eq '"mem_percent":34' "${TMP}/out/stats.json" || fail "mem field missing"
grep -Eq '"disk_percent":56' "${TMP}/out/stats.json" || fail "disk field missing"
grep -Eq '"ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' \
  "${TMP}/out/stats.json" || fail "ts missing or not UTC Z"
shopt -s nullglob
leftovers=("${TMP}/out/stats.json.tmp."*)
shopt -u nullglob
[[ ${#leftovers[@]} -eq 0 ]] || fail "tmp file left behind: ${leftovers[*]}"
pass "atomic JSON write"

welcome_stats_main
grep -Eq '"mem_percent":75' "${TMP}/out/stats.json" || fail "main did not refresh mem"
pass "welcome_stats_main end-to-end"

echo "All welcome-stats offline tests passed."
