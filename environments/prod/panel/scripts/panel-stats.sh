#!/usr/bin/env bash
# Sample Host CPU / memory / disk / Host Volume usage into Workload durable JSON.
# Invoked by panel-stats.service (Platform User systemd --user).
# Paths overridable for Unit Tests (read at call time).
set -euo pipefail

panel_stats_proc_root() {
  printf '%s\n' "${PANEL_STATS_PROC:-/proc}"
}

panel_stats_disk_path() {
  printf '%s\n' "${PANEL_STATS_DISK_PATH:-/}"
}

panel_stats_host_volume() {
  printf '%s\n' "${PANEL_STATS_HOST_VOLUME:-/var/lib/host-volume}"
}

panel_stats_out_file() {
  if [[ -n "${PANEL_STATS_OUT_FILE:-}" ]]; then
    printf '%s\n' "${PANEL_STATS_OUT_FILE}"
    return 0
  fi
  printf '%s\n' \
    "${PANEL_STATS_OUT_DIR:-/var/lib/host-volume/data/workloads/panel/stats}/stats.json"
}

panel_stats_cpu_sample_sec() {
  printf '%s\n' "${PANEL_STATS_CPU_SAMPLE_SEC:-1}"
}

panel_stats_read_cpu() {
  # total idle — fields from /proc/stat "cpu" line (Linux).
  awk '/^cpu / {
    total = 0
    for (i = 2; i <= NF; i++) total += $i
    idle = $5
    print total, idle
    exit
  }' "$(panel_stats_proc_root)/stat"
}

panel_stats_cpu_percent() {
  local t1 i1 t2 i2 dt di used sample_sec
  sample_sec="$(panel_stats_cpu_sample_sec)"
  read -r t1 i1 < <(panel_stats_read_cpu)
  if [[ "${sample_sec}" != "0" ]]; then
    sleep "${sample_sec}"
  fi
  read -r t2 i2 < <(panel_stats_read_cpu)
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

panel_stats_mem_percent() {
  local total available used meminfo
  meminfo="$(panel_stats_proc_root)/meminfo"
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

# Percent used for the filesystem that contains PATH (df -P).
panel_stats_fs_percent() {
  local path="$1" pct
  pct="$(df -P "${path}" 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $5; exit }')"
  if [[ -z "${pct}" || ! "${pct}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' 0
    return 0
  fi
  if [[ "${pct}" -gt 100 ]]; then
    pct=100
  fi
  printf '%s\n' "${pct}"
}

panel_stats_disk_percent() {
  panel_stats_fs_percent "$(panel_stats_disk_path)"
}

panel_stats_host_volume_percent() {
  panel_stats_fs_percent "$(panel_stats_host_volume)"
}

panel_stats_write_json() {
  local cpu_percent="$1" mem_percent="$2" disk_percent="$3" host_volume_percent="$4"
  local ts tmp out
  out="$(panel_stats_out_file)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "${out}")"
  tmp="${out}.tmp.$$"
  printf '{"ts":"%s","cpu_percent":%s,"mem_percent":%s,"disk_percent":%s,"host_volume_percent":%s}\n' \
    "${ts}" "${cpu_percent}" "${mem_percent}" "${disk_percent}" "${host_volume_percent}" >"${tmp}"
  mv -f "${tmp}" "${out}"
}

panel_stats_main() {
  local cpu_percent mem_percent disk_percent host_volume_percent
  cpu_percent="$(panel_stats_cpu_percent)"
  mem_percent="$(panel_stats_mem_percent)"
  disk_percent="$(panel_stats_disk_percent)"
  host_volume_percent="$(panel_stats_host_volume_percent)"
  panel_stats_write_json \
    "${cpu_percent}" "${mem_percent}" "${disk_percent}" "${host_volume_percent}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  panel_stats_main
fi
