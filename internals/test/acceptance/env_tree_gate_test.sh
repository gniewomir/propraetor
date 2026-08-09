#!/usr/bin/env bash
# Seam: Acceptance Environment tree identity gate (snapshot after baseline / assert after case).
# Excludes environments/<slug>/.ssh/ (Host-session TOFU). Covers gitignored files (.env*).
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "${CASE_DIR}/lib.sh"
# shellcheck source=baseline.sh
source "${CASE_DIR}/baseline.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

umask 077
TMP="$(mktemp -d "${TMPDIR:-/tmp}/acceptance-env-tree.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

export REPO_ROOT="${TMP}"
export PLATFORM_ENV="test"
ENV_TREE="${TMP}/environments/test"
mkdir -p "${ENV_TREE}/wl" "${ENV_TREE}/.ssh"
printf 'intent\n' >"${ENV_TREE}/wl/manifest.json"
printf 'ROOT_DB_USER=u\n' >"${ENV_TREE}/.env"
printf 'oldkey ssh-ed25519 AAAA\n' >"${ENV_TREE}/.ssh/known_hosts"

# --- unchanged tree passes ---
snap="$(acceptance_env_tree_snapshot)" || fail "snapshot should succeed"
[[ -d "${snap}" ]] || fail "snapshot must return a directory"
acceptance_env_tree_assert_matches "${snap}" \
  || fail "identical tree must pass"
pass "identical Environment tree asserts clean"

# --- .env mutation fails ---
snap="$(acceptance_env_tree_snapshot)" || fail "snapshot before .env mutate"
printf 'ROOT_DB_USER=mutated\n' >"${ENV_TREE}/.env"
if acceptance_env_tree_assert_matches "${snap}" 2>"${TMP}/err-env"; then
  fail ".env mutation must fail assert"
fi
grep -Eq '\.env|differ|FAIL' "${TMP}/err-env" \
  || fail "mutation failure unclear: $(cat "${TMP}/err-env")"
# restore for next checks
printf 'ROOT_DB_USER=u\n' >"${ENV_TREE}/.env"
pass ".env mutation fails Environment tree assert"

# --- leftover .env.override fails ---
snap="$(acceptance_env_tree_snapshot)" || fail "snapshot before override"
printf 'A=fixture\n' >"${ENV_TREE}/.env.override"
if acceptance_env_tree_assert_matches "${snap}" 2>"${TMP}/err-ov"; then
  fail "leftover .env.override must fail assert"
fi
rm -f "${ENV_TREE}/.env.override"
pass "leftover .env.override fails Environment tree assert"

# --- leftover fixture Workload fails ---
snap="$(acceptance_env_tree_snapshot)" || fail "snapshot before fixture"
mkdir -p "${ENV_TREE}/ephemeral-wl"
printf '{}\n' >"${ENV_TREE}/ephemeral-wl/manifest.json"
if acceptance_env_tree_assert_matches "${snap}" 2>"${TMP}/err-wl"; then
  fail "leftover fixture Workload must fail assert"
fi
rm -rf "${ENV_TREE}/ephemeral-wl"
pass "leftover fixture Workload fails Environment tree assert"

# --- .ssh/ changes are ignored ---
snap="$(acceptance_env_tree_snapshot)" || fail "snapshot before known_hosts change"
printf 'newkey ssh-ed25519 BBBB\n' >"${ENV_TREE}/.ssh/known_hosts"
acceptance_env_tree_assert_matches "${snap}" \
  || fail ".ssh/known_hosts change must be ignored"
pass ".ssh/ mutations are excluded from Environment tree gate"

echo "All acceptance env-tree gate checks passed."
