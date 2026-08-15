#!/usr/bin/env bash
# Host Volume path vocabulary (Host-side).
#
# Single surface for mount root, SoT owner trees, and Persist locations so a later
# layout cut (ADR-0054) is a mechanical switch of these helpers — not a path
# scavenger hunt. #214 keeps today's live contract (ADR-0041):
#   mount: /var/lib/host-volume
#   SoT:   <mount>/internals/{fabric,components,workloads,host-scripts}
#   Persist-today: <mount>/data/{fabric,components,workloads}
#
# Naming: host_volume_* — never "internals_*" as the API — so the Host Volume
# SoT segment "internals/" is not confused with the operator-machine repo path
# internals/ (fabric/components/host-scripts/lib in git).
#
# Ambient override: HV_ROOT (default /var/lib/host-volume).

host_volume_mount_root() {
  printf '%s\n' "${HV_ROOT:-/var/lib/host-volume}"
}

# SoT parent under the mount (ADR-0041: …/internals). Not the operator-machine repo path.
host_volume_sot_root() {
  printf '%s\n' "$(host_volume_mount_root)/internals"
}

# Persist-today parent under the mount (ADR-0041 top-level data/; ADR-0054 will nest Persist).
host_volume_persist_root() {
  printf '%s\n' "$(host_volume_mount_root)/data"
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

host_volume_fabric_persist() {
  printf '%s\n' "$(host_volume_persist_root)/fabric"
}

host_volume_workload_persist() {
  local basename="${1:?host_volume_workload_persist: Workload basename required}"
  printf '%s\n' "$(host_volume_persist_root)/workloads/${basename}"
}

host_volume_component_persist() {
  local name="${1:?host_volume_component_persist: Component name required}"
  printf '%s\n' "$(host_volume_persist_root)/components/${name}"
}

host_volume_workloads_persist_root() {
  printf '%s\n' "$(host_volume_persist_root)/workloads"
}

host_volume_components_persist_root() {
  printf '%s\n' "$(host_volume_persist_root)/components"
}
