#!/usr/bin/env bash
# CLI argv seam: positionals then flags (ADR-0039).
# shellcheck disable=SC2154  # PREFIX_* assigned via eval inside cli_parse
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=cli.sh
source "${REPO_ROOT}/internals/lib/cli.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- flags only ---
cli_parse T flag:yes:bool flag:env:value -- --yes --env test \
  || fail "flags-only parse"
[[ "${T_yes}" == "1" ]] || fail "yes want 1 got '${T_yes}'"
[[ "${T_env}" == "test" ]] || fail "env want test got '${T_env}'"
[[ "${T_env_set}" == "1" ]] || fail "env_set want 1"
pass "flags only: --yes --env test"

cli_parse T flag:yes:bool flag:env:value -- --env=prod --yes \
  || fail "flag order"
[[ "${T_yes}" == "1" && "${T_env}" == "prod" ]] || fail "flag order values"
pass "flag order arbitrary"

cli_parse T flag:yes:bool flag:env:value -- \
  || fail "defaults"
[[ "${T_yes}" == "0" && "${T_env}" == "" && "${T_env_set}" == "0" ]] || fail "defaults wrong"
pass "bool/value defaults"

# --- positionals then flags ---
cli_parse T pos:suite:required pos:selector:optional flag:verbose:bool flag:env:value -- \
  acceptance 1100-podman --verbose --env test \
  || fail "pos then flags"
[[ "${T_suite}" == "acceptance" ]] || fail "suite"
[[ "${T_selector}" == "1100-podman" ]] || fail "selector"
[[ "${T_verbose}" == "1" && "${T_env}" == "test" ]] || fail "flags after pos"
pass "positionals then flags"

cli_parse T pos:suite:required pos:selector:optional flag:verbose:bool flag:env:value -- \
  acceptance --env test \
  || fail "optional positional omitted"
[[ "${T_suite}" == "acceptance" && -z "${T_selector}" && "${T_env}" == "test" ]] \
  || fail "optional omitted values"
pass "optional positional omitted"

cli_parse T pos:suite:required pos:selector:optional flag:verbose:bool flag:from:value flag:env:value -- \
  acceptance --from 1100 --verbose --env test \
  || fail "from flag"
[[ "${T_suite}" == "acceptance" && -z "${T_selector}" ]] || fail "from: suite/selector"
[[ "${T_from}" == "1100" && "${T_from_set}" == "1" && "${T_verbose}" == "1" ]] || fail "from flag values"
pass "--from after optional selector omitted"

# --- reject bad shapes ---
if cli_parse T pos:suite:required flag:env:value -- --env test acceptance 2>/dev/null; then
  fail "expected reject flag before positional"
fi
pass "rejects flag before positional"

if cli_parse T pos:suite:required flag:verbose:bool flag:env:value -- \
  acceptance --verbose sel 2>/dev/null; then
  fail "expected reject positional after flags"
fi
pass "rejects positional after flags"

if cli_parse T flag:env:value -- --env 2>/dev/null; then
  fail "expected reject --env without value"
fi
pass "rejects --env without value"

if cli_parse T flag:env:value -- --env= 2>/dev/null; then
  fail "expected reject empty --env="
fi
pass "rejects empty --env="

if cli_parse T flag:env:value -- --env test --env prod 2>/dev/null; then
  fail "expected reject duplicate --env"
fi
pass "rejects duplicate value flag"

if cli_parse T flag:yes:bool -- --yes=1 2>/dev/null; then
  fail "expected reject --yes=value"
fi
pass "rejects bool with ="

if cli_parse T flag:yes:bool -- --bogus 2>/dev/null; then
  fail "expected reject unknown flag"
fi
pass "rejects unknown flag"

if cli_parse T pos:a:required -- 2>/dev/null; then
  fail "expected reject missing required positional"
fi
pass "rejects missing required positional"

if cli_parse T pos:a:required -- one two 2>/dev/null; then
  fail "expected reject too many positionals"
fi
pass "rejects too many positionals"

if cli_parse T flag:bundle:value:required -- 2>/dev/null; then
  fail "expected reject missing required value flag"
fi
pass "rejects missing required value flag"

# --- cli_operator_parse always includes --env ---
cli_operator_parse O flag:yes:bool -- --yes --env staging \
  || fail "operator parse"
[[ "${O_yes}" == "1" && "${O_env}" == "staging" && "${O_env_set}" == "1" ]] \
  || fail "operator values"
pass "cli_operator_parse includes --env"

# --- rest: peel known flags anywhere; remainder preserved ---
cli_parse T flag:env:value rest:ssh_args -- --env test uptime -p 22 \
  || fail "rest with leading flags"
[[ "${T_env}" == "test" ]] || fail "rest env"
[[ "${#T_ssh_args[@]}" -eq 3 ]] || fail "rest arity want 3 got ${#T_ssh_args[@]}"
[[ "${T_ssh_args[0]}" == "uptime" && "${T_ssh_args[1]}" == "-p" && "${T_ssh_args[2]}" == "22" ]] \
  || fail "rest tokens"
pass "rest: flags then remote argv"

cli_parse T flag:env:value rest:ssh_args -- uptime --env prod \
  || fail "rest with trailing --env"
[[ "${T_env}" == "prod" && "${#T_ssh_args[@]}" -eq 1 && "${T_ssh_args[0]}" == "uptime" ]] \
  || fail "rest peel from anywhere"
pass "rest: peels --env from anywhere"

echo "All cli_parse checks passed."
