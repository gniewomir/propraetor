#!/usr/bin/env bash
# Shared Unit fixture: temp Environments root with a fixed Domain assignment (ADR-0051).
# Requires TMP_DIR. Exports PROPRAETOR_ENVIRONMENTS_ROOT. Prints nothing.
# Apex is unit.example so fixtures stay independent of live environments/test/domains.json.
unit_environments_root_fixture() {
  local envs_root="${TMP_DIR:?unit_environments_root_fixture requires TMP_DIR}/environments-root"
  mkdir -p "${envs_root}/test"
  printf '%s\n' '{"unit.example":{"names":["@", "www", "api", "test-acme"]}}' \
    >"${envs_root}/test/domains.json"
  export PROPRAETOR_ENVIRONMENTS_ROOT="${envs_root}"
}
