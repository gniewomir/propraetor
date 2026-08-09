#!/usr/bin/env bash
# Environment-scoped dotenv bag: .env + optional .env.override (ADR-0035 / ADR-0049).
# Sourced by Environment Configuration and Database admin credential helpers.
# Not an operator entrypoint. File merge only — callers apply shell overlay.
#
# Public:
#   environment_dotenv_bag ENV_DIR
#     Parse environments/<slug>/.env then overlay .env.override (override wins
#     on key collision). Strict dotenv subset. Absent either file is a no-op for
#     that layer. Print KEY=value lines on stdout (stable key order: first-seen
#     from .env, then new keys from override). Fail closed on invalid grammar.

environment_dotenv_bag() {
  local env_dir="${1:?environment_dotenv_bag: Environment dir required}"
  local dotenv="${env_dir}/.env"
  local override="${env_dir}/.env.override"

  python3 - "${dotenv}" "${override}" <<'PY'
import os
import re
import sys

dotenv_path, override_path = sys.argv[1], sys.argv[2]
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def parse_file(path):
    """Return ordered (key, value) pairs; later keys in the same file overwrite."""
    ordered = []
    index = {}
    if not os.path.isfile(path):
        return ordered, index
    with open(path, encoding="utf-8") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if line.strip() == "" or line.lstrip().startswith("#"):
                continue
            if line.startswith("export ") or line.startswith("export\t"):
                raise SystemExit(
                    f"invalid dotenv at {path}:{lineno}: export is not allowed"
                )
            if "=" not in line:
                raise SystemExit(
                    f"invalid dotenv at {path}:{lineno}: expected KEY=value"
                )
            key, _, val = line.partition("=")
            if not KEY_RE.match(key):
                raise SystemExit(
                    f"invalid dotenv at {path}:{lineno}: bad key name"
                )
            if "\n" in val or "\r" in val:
                raise SystemExit(
                    f"invalid dotenv at {path}:{lineno}: multiline values are not allowed"
                )
            if val.startswith("'") and val.endswith("'") and len(val) >= 2:
                raise SystemExit(
                    f"invalid dotenv at {path}:{lineno}: single-quoted values are not allowed"
                )
            if val.startswith('"') and val.endswith('"') and len(val) >= 2:
                val = val[1:-1]
            if "${" in val:
                raise SystemExit(
                    f"invalid dotenv at {path}:{lineno}: interpolation is not allowed"
                )
            if key in index:
                ordered[index[key]] = (key, val)
            else:
                index[key] = len(ordered)
                ordered.append((key, val))
    return ordered, index


base_ordered, base_index = parse_file(dotenv_path)
ov_ordered, _ = parse_file(override_path)

# Start from .env order; overlay override values; append override-only keys.
merged = list(base_ordered)
merged_index = dict(base_index)
for key, val in ov_ordered:
    if key in merged_index:
        merged[merged_index[key]] = (key, val)
    else:
        merged_index[key] = len(merged)
        merged.append((key, val))

for key, val in merged:
    print(f"{key}={val}")
PY
}
