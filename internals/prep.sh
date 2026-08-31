#!/usr/bin/env bash
# Artifact Prep — obtain/build and stage deployable Artifact zips for every Environment
# Workload (ADR-0059). Operator-local; no Host delivery. Deploy invokes this as phase 0.
# Environment: omitted / --env default|test → workspace default; --env <slug> otherwise (ADR-0019).
# Usage: ./internals/prep.sh [--env <slug>]
# Requires: PROPRAETOR_PROJECTS_ROOT when any Workload uses local Source (Operator dotenv).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
# shellcheck source=lib/cli.sh
source "${REPO_ROOT}/internals/lib/cli.sh"
# shellcheck source=lib/environment/environment.sh
source "${REPO_ROOT}/internals/lib/environment/environment.sh"
# shellcheck source=lib/operator/operator-dotenv.sh
source "${REPO_ROOT}/internals/lib/operator/operator-dotenv.sh"
# shellcheck source=lib/artifact/prep.sh
source "${REPO_ROOT}/internals/lib/artifact/prep.sh"

operator_dotenv_load "${REPO_ROOT}" || exit 1

CLI_env=""
cli_operator_parse CLI -- "$@" || exit 1
environment_activate "${STACK_DIR}" "${CLI_env}" || exit 1

ENV_DIR="$(environments_dir_for "${PLATFORM_ENV}")" || exit 1

prepped="$(artifact_prep_environment "${ENV_DIR}")" || exit 1
echo "Artifact Prep completed for Environment '${PLATFORM_ENV}' (${prepped} Workload(s))."
