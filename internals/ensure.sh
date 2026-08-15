#!/usr/bin/env bash
# Deploy ladder orchestrator — Fabric → Mirror → Orphan Reap → Component Setup
# (pre-workloads) → Workloads → Component Setup (post-workloads).
# Composes Host ensure/purge-orphans cogs for CI and Acceptance; root deploy.sh invokes this after
# IHP Done. Does not run Stack Apply. ADR-0041 / ADR-0043 / ADR-0054 / #217.
# Environment: omitted / --env default|test → workspace default; --env <slug> otherwise (ADR-0019).
# Usage: ./internals/ensure.sh [--env <slug>]
# Optional: PLATFORM_USER=platform (forwarded by child cogs).
# Requires: Operator Configuration private key path (PROPRAETOR_PRIVATE_KEY_PATH).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
# shellcheck source=lib/cli.sh
source "${REPO_ROOT}/internals/lib/cli.sh"
# shellcheck source=lib/environment/environment.sh
source "${REPO_ROOT}/internals/lib/environment/environment.sh"
# shellcheck source=lib/operator/operator-dotenv.sh
source "${REPO_ROOT}/internals/lib/operator/operator-dotenv.sh"
# shellcheck source=lib/operator/operator-configuration.sh
source "${REPO_ROOT}/internals/lib/operator/operator-configuration.sh"

operator_dotenv_load "${REPO_ROOT}" || exit 1
operator_configuration_require private || exit 1

CLI_env=""
cli_operator_parse CLI -- "$@" || exit 1
environment_activate "${STACK_DIR}" "${CLI_env}" || exit 1

ENV_FLAG=(--env "${PLATFORM_ENV}")

"${REPO_ROOT}/internals/ensure-fabric.sh" "${ENV_FLAG[@]}"
"${REPO_ROOT}/internals/ensure-mirror.sh" "${ENV_FLAG[@]}"
"${REPO_ROOT}/internals/purge-orphans.sh" "${ENV_FLAG[@]}"
"${REPO_ROOT}/internals/ensure-components.sh" pre-workloads "${ENV_FLAG[@]}"
"${REPO_ROOT}/internals/ensure-workloads.sh" "${ENV_FLAG[@]}"
"${REPO_ROOT}/internals/ensure-components.sh" post-workloads "${ENV_FLAG[@]}"

echo "Deploy ladder finished for Environment '${PLATFORM_ENV}'."
