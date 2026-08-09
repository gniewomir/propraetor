#!/usr/bin/env bash
# Repo-root .env baseline for Provider Credential + Operator Configuration (ADR-0038).
# Sourced by operator entrypoints — not an entrypoint itself.
#
# Public:
#   operator_dotenv_load REPO_ROOT
#     If REPO_ROOT/.env is missing, no-op. Else parse strict dotenv, allowlist only
#     DIGITALOCEAN_TOKEN / PROPRAETOR_PUBLIC_KEY_PATH / PROPRAETOR_PRIVATE_KEY_PATH /
#     PROPRAETOR_ACME_EMAIL.
#     Non-empty process-environment values win; empty file values are unset.
#     Unknown keys and invalid grammar fail closed.

operator_dotenv_load() {
  local repo_root="${1:?operator_dotenv_load requires repo root}"
  local dotenv="${repo_root}/.env"
  local exports

  [[ -f "${dotenv}" ]] || return 0

  exports="$(mktemp "${TMPDIR:-/tmp}/operator-dotenv.XXXXXX")"
  if ! python3 - "${dotenv}" "${exports}" <<'PY'
import os, re, sys

dotenv_path, outfile = sys.argv[1], sys.argv[2]
ALLOW = {
    "DIGITALOCEAN_TOKEN",
    "PROPRAETOR_PUBLIC_KEY_PATH",
    "PROPRAETOR_PRIVATE_KEY_PATH",
    "PROPRAETOR_ACME_EMAIL",
}
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
file_vals = {}

with open(dotenv_path, encoding="utf-8") as f:
    for lineno, raw in enumerate(f, 1):
        line = raw.rstrip("\n")
        if line.strip() == "" or line.lstrip().startswith("#"):
            continue
        if line.startswith("export ") or line.startswith("export\t"):
            raise SystemExit(
                "invalid dotenv at %s:%d: export is not allowed" % (dotenv_path, lineno)
            )
        if "=" not in line:
            raise SystemExit(
                "invalid dotenv at %s:%d: expected KEY=value" % (dotenv_path, lineno)
            )
        key, _, val = line.partition("=")
        if not KEY_RE.match(key):
            raise SystemExit(
                "invalid dotenv at %s:%d: bad key name" % (dotenv_path, lineno)
            )
        if key not in ALLOW:
            raise SystemExit(
                "operator dotenv at %s:%d: unknown key %s (allowlist: %s)"
                % (dotenv_path, lineno, key, ", ".join(sorted(ALLOW)))
            )
        if "\n" in val or "\r" in val:
            raise SystemExit(
                "invalid dotenv at %s:%d: multiline values are not allowed"
                % (dotenv_path, lineno)
            )
        if val.startswith("'") and val.endswith("'") and len(val) >= 2:
            raise SystemExit(
                "invalid dotenv at %s:%d: single-quoted values are not allowed"
                % (dotenv_path, lineno)
            )
        if val.startswith('"') and val.endswith('"') and len(val) >= 2:
            val = val[1:-1]
        if "${" in val:
            raise SystemExit(
                "invalid dotenv at %s:%d: interpolation is not allowed"
                % (dotenv_path, lineno)
            )
        file_vals[key] = val

def sh_single(s):
    return "'" + s.replace("'", "'\"'\"'") + "'"

lines = []
for key, val in file_vals.items():
    if val == "":
        continue
    env_val = os.environ.get(key, "")
    if env_val != "":
        continue
    lines.append("export %s=%s" % (key, sh_single(val)))

with open(outfile, "w", encoding="utf-8") as out:
    out.write("\n".join(lines))
    if lines:
        out.write("\n")
PY
  then
    rm -f "${exports}"
    return 1
  fi
  # shellcheck disable=SC1090  # generated exports from allowlisted dotenv keys
  source "${exports}"
  rm -f "${exports}"
  return 0
}
