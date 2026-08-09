#!/usr/bin/env bash
# Unit tests: panel Host usage sampler (paths / math / atomic JSON write).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/environments/prod/panel/scripts/panel-stats.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -f "${SCRIPT}" ]] || fail "missing ${SCRIPT}"

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/panel-stats.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/proc" "${TMP}/hv" "${TMP}/disk" "${TMP}/out"
# MemTotal 1000 kB, MemAvailable 250 kB → 75% used
printf 'MemTotal:       1000 kB\nMemAvailable:    250 kB\n' >"${TMP}/proc/meminfo"
# Two identical cpu samples (CPU_SAMPLE_SEC=0) → 0%
printf 'cpu  100 0 0 100 0 0 0 0 0 0\n' >"${TMP}/proc/stat"

# shellcheck source=../../environments/prod/panel/scripts/panel-stats.sh
source "${SCRIPT}"

export PANEL_STATS_PROC="${TMP}/proc"
export PANEL_STATS_DISK_PATH="${TMP}/disk"
export PANEL_STATS_HOST_VOLUME="${TMP}/hv"
export PANEL_STATS_OUT_DIR="${TMP}/out"
export PANEL_STATS_OUT_FILE="${TMP}/out/stats.json"
export PANEL_STATS_CPU_SAMPLE_SEC=0

[[ "$(panel_stats_mem_percent)" == "75" ]] || fail "mem percent expected 75"
pass "mem percent from MemTotal/MemAvailable"

[[ "$(panel_stats_cpu_percent)" == "0" ]] || fail "cpu percent expected 0 on identical samples"
pass "cpu percent handles zero delta"

dd if=/dev/zero of="${TMP}/disk/pad" bs=1024 count=4 status=none 2>/dev/null || true
dd if=/dev/zero of="${TMP}/hv/pad" bs=1024 count=4 status=none 2>/dev/null || true
disk="$(panel_stats_disk_percent)"
hv="$(panel_stats_host_volume_percent)"
[[ "${disk}" =~ ^[0-9]+$ ]] || fail "disk percent not an integer: ${disk}"
[[ "${disk}" -ge 0 && "${disk}" -le 100 ]] || fail "disk percent out of range: ${disk}"
[[ "${hv}" =~ ^[0-9]+$ ]] || fail "host volume percent not an integer: ${hv}"
[[ "${hv}" -ge 0 && "${hv}" -le 100 ]] || fail "host volume percent out of range: ${hv}"
pass "disk and host volume percents are integers 0–100"

panel_stats_write_json 12 34 56 78
grep -Eq '"cpu_percent":12' "${TMP}/out/stats.json" || fail "cpu field missing"
grep -Eq '"mem_percent":34' "${TMP}/out/stats.json" || fail "mem field missing"
grep -Eq '"disk_percent":56' "${TMP}/out/stats.json" || fail "disk field missing"
grep -Eq '"host_volume_percent":78' "${TMP}/out/stats.json" || fail "host volume field missing"
grep -Eq '"ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' \
  "${TMP}/out/stats.json" || fail "ts missing or not UTC Z"
shopt -s nullglob
leftovers=("${TMP}/out/stats.json.tmp."*)
shopt -u nullglob
[[ ${#leftovers[@]} -eq 0 ]] || fail "tmp file left behind: ${leftovers[*]}"
pass "atomic JSON write"

panel_stats_main
grep -Eq '"mem_percent":75' "${TMP}/out/stats.json" || fail "main did not refresh mem"
grep -Eq '"host_volume_percent":[0-9]+' "${TMP}/out/stats.json" \
  || fail "main did not write host_volume_percent"
pass "panel_stats_main end-to-end"

echo "All panel-stats offline tests passed."
