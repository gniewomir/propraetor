#!/usr/bin/env bash
# Host Volume path vocabulary (Host-side).
#
# Single surface for mount root, SoT owner trees, and nested Persist (ADR-0054).
#   mount: /host-volume
#   SoT:   <mount>/{fabric,components,workloads,host-scripts}
#   Persist: <owner>/persist  (Workloads and Components only; not Fabric / host-scripts)
#
# Naming: host_volume_* — never "internals_*" as the API — so this layout is not
# confused with the operator-machine repo path internals/ (fabric/components/
# host-scripts/lib in git).
#
# Ambient override: HV_ROOT (default /host-volume).

host_volume_mount_root() {
  printf '%s\n' "${HV_ROOT:-/host-volume}"
}

# SoT parent under the mount (ADR-0054: owner trees live at the mount root).
# Not the operator-machine repo path.
host_volume_sot_root() {
  host_volume_mount_root
}

host_volume_host_scripts_root() {
  printf '%s\n' "$(host_volume_sot_root)/host-scripts"
}

host_volume_fabric_root() {
  printf '%s\n' "$(host_volume_sot_root)/fabric"
}

host_volume_components_sot_root() {
  printf '%s\n' "$(host_volume_sot_root)/components"
}

host_volume_component_sot() {
  local name="${1:?host_volume_component_sot: Component name required}"
  printf '%s\n' "$(host_volume_components_sot_root)/${name}"
}

host_volume_workloads_sot_root() {
  printf '%s\n' "$(host_volume_sot_root)/workloads"
}

host_volume_workload_sot() {
  local basename="${1:?host_volume_workload_sot: Workload basename required}"
  printf '%s\n' "$(host_volume_workloads_sot_root)/${basename}"
}

host_volume_workload_persist() {
  local basename="${1:?host_volume_workload_persist: Workload basename required}"
  printf '%s\n' "$(host_volume_workload_sot "${basename}")/persist"
}

host_volume_component_persist() {
  local name="${1:?host_volume_component_persist: Component name required}"
  printf '%s\n' "$(host_volume_component_sot "${name}")/persist"
}
