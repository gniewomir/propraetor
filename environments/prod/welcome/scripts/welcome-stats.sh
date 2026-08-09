#!/usr/bin/env bash
# Sample Host CPU / memory / disk usage into Workload durable JSON for welcome.
# Invoked by welcome-stats.service (Platform User systemd --user).
# Paths overridable for Unit Tests (read at call time).
set -euo pipefail

welcome_stats_proc_root() {
  printf '%s\n' "${WELCOME_STATS_PROC:-/proc}"
}

welcome_stats_host_volume() {
  printf '%s\n' "${WELCOME_STATS_HOST_VOLUME:-/var/lib/host-volume}"
}

welcome_stats_out_file() {
  if [[ -n "${WELCOME_STATS_OUT_FILE:-}" ]]; then
    printf '%s\n' "${WELCOME_STATS_OUT_FILE}"
    return 0
  fi
  printf '%s\n' \
    "${WELCOME_STATS_OUT_DIR:-/var/lib/host-volume/data/workloads/welcome/stats}/stats.json"
}

welcome_stats_cpu_sample_sec() {
  printf '%s\n' "${WELCOME_STATS_CPU_SAMPLE_SEC:-1}"
}

welcome_stats_read_cpu() {
  # total idle — fields from /proc/stat "cpu" line (Linux).
  awk '/^cpu / {
    total = 0
    for (i = 2; i <= NF; i++) total += $i
    idle = $5
    print total, idle
    exit
  }' "$(welcome_stats_proc_root)/stat"
}

welcome_stats_cpu_percent() {
  local t1 i1 t2 i2 dt di used sample_sec
  sample_sec="$(welcome_stats_cpu_sample_sec)"
  read -r t1 i1 < <(welcome_stats_read_cpu)
  if [[ "${sample_sec}" != "0" ]]; then
    sleep "${sample_sec}"
  fi
  read -r t2 i2 < <(welcome_stats_read_cpu)
  dt=$((t2 - t1))
  di=$((i2 - i1))
  if [[ "${dt}" -le 0 ]]; then
    printf '%s\n' 0
    return 0
  fi
  used=$((100 * (dt - di) / dt))
  if [[ "${used}" -lt 0 ]]; then
    used=0
  elif [[ "${used}" -gt 100 ]]; then
    used=100
  fi
  printf '%s\n' "${used}"
}

welcome_stats_mem_percent() {
  local total available used meminfo
  meminfo="$(welcome_stats_proc_root)/meminfo"
  total="$(awk '/^MemTotal:/ {print $2; exit}' "${meminfo}")"
  available="$(awk '/^MemAvailable:/ {print $2; exit}' "${meminfo}")"
  if [[ -z "${total}" || "${total}" -le 0 || -z "${available}" ]]; then
    printf '%s\n' 0
    return 0
  fi
  used=$((100 * (total - available) / total))
  if [[ "${used}" -lt 0 ]]; then
    used=0
  elif [[ "${used}" -gt 100 ]]; then
    used=100
  fi
  printf '%s\n' "${used}"
}

welcome_stats_disk_percent() {
  local pct
  pct="$(df -P "$(welcome_stats_host_volume)" 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $5; exit }')"
  if [[ -z "${pct}" || ! "${pct}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' 0
    return 0
  fi
  if [[ "${pct}" -gt 100 ]]; then
    pct=100
  fi
  printf '%s\n' "${pct}"
}

welcome_stats_write_json() {
  local cpu_percent="$1" mem_percent="$2" disk_percent="$3" ts tmp out
  out="$(welcome_stats_out_file)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "${out}")"
  tmp="${out}.tmp.$$"
  printf '{"ts":"%s","cpu_percent":%s,"mem_percent":%s,"disk_percent":%s}\n' \
    "${ts}" "${cpu_percent}" "${mem_percent}" "${disk_percent}" >"${tmp}"
  mv -f "${tmp}" "${out}"
}

welcome_stats_main() {
  local cpu_percent mem_percent disk_percent
  cpu_percent="$(welcome_stats_cpu_percent)"
  mem_percent="$(welcome_stats_mem_percent)"
  disk_percent="$(welcome_stats_disk_percent)"
  welcome_stats_write_json "${cpu_percent}" "${mem_percent}" "${disk_percent}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  welcome_stats_main
fi
