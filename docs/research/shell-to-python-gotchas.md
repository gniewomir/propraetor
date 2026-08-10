# Shell (Bash) → Python gotchas for portable ops scripts

**Researched:** 2026-08-10  
**Question:** What are the authoritative gotchas, behavioral mismatches, and policy choices when moving from Bash shell scripts to Python for operator/infra automation that must remain portable across Linux and macOS?  
**Scope:** Gotchas when *replacing* Bash with Python (or growing Python surface area) for ops/infra CLIs that shell out (`podman`, `ssh`, `terraform`, `curl`, …), parse/emit text, exit with meaningful status codes, run on Ubuntu Hosts and macOS operators, may run over SSH, and touch env files / JSON / paths / signals / subprocesses. Not a Propraetor product design doc; not a full Python style guide; not Windows. Secondary blogs used only as leads and verified against primary docs/PEPs/specs.

**Repo constraint:** Shared scripts today are Bash (`#!/usr/bin/env bash`, `set -euo pipefail`), Bash floor stock macOS 3.2, ShellCheck for shell, GNU vs BSD landmines in `docs/research/shell-linux-macos-portability.md` / `CODING_STANDARDS.md`. The tree already uses occasional `python3 -` heredoc snippets (dotenv merge, domains JSON, Manifest parsing) and at least one `#!/usr/bin/env python3` Host helper — so partial Python exists; this note is about broader migration / writing new logic in Python instead of Bash.

---

## Verdict

| Recommendation | Implication for this repo |
| --- | --- |
| Prefer **`python3` / `#!/usr/bin/env python3`**, never bare `python` | Aligns with [PEP 394](https://peps.python.org/pep-0394/); Ubuntu may lack `python` unless `python-is-python3`; macOS often has no `python` at all |
| Treat **macOS `python3` as not a single stock runtime** | `/usr/bin/python3` is Apple/CLT-controlled (often old); Homebrew/`python.org`/`pyenv` may shadow it via PATH. `env python3` is PATH-dependent — same class of trap as `env bash` → Bash 3.2 |
| Assume **Ubuntu Host has `python3`**; do **not** assume a modern floor without policy | Ubuntu documents `python3` as part of the default install ([Ubuntu Python setup](https://ubuntu.com/developers/docs/howto/python-setup/)); minor version follows the release. Decide a floor (see Open policy choices) |
| Default to **stdlib-only** for Host/shared automation unless packaging is designed | Pip into system Python is blocked/discouraged ([PEP 668](https://peps.python.org/pep-0668/); Ubuntu externally managed env). Venvs on every Host are a deployment tax |
| Prefer **`subprocess.run([...], check=True)`** with argv lists; avoid `shell=True` | Escapes shell injection and word-splitting; use a real shell only when you need shell pipeline/redir semantics ([subprocess Security Considerations](https://docs.python.org/3/library/subprocess.html#security-considerations)) |
| Map Bash `set -euo pipefail` to **explicit** exceptions + exit codes | Python does **not** auto-fail on nonzero child status unless `check=True` / `CalledProcessError` handling. Uncaught exceptions → nonzero exit; decide status conventions (`1` vs `2` for usage) |
| Keep **thin Bash entrypoints** calling Python modules where SSH/bootstrap or “Bash always there” matters | Matches current `python3 - <<'PY'` pattern; avoids shipping a venv to remote Host for tiny helpers |
| Do **not** treat Python as a free portability win for thin CLI wrappers | Interpreter cold start + PATH/`python3` variance can make “one `ssh` + one `podman`” worse as Python than as Bash |
| Lint/test swap is **not** 1:1 with ShellCheck | Need a Python gate (ruff/mypy/pytest or equivalent) if Python grows; ShellCheck will not cover `.py` |

**Open policy choices (human must decide):** Python version floor; whether Host scripts may assume `python3` always; stdlib-only vs allowed deps/venv; whether macOS operators must install a non-Apple Python; when to keep Bash vs move logic to Python. This note does not invent Propraetor policy.

---

## Authoritative sources ranked

| Rank | Source | Owns |
| --- | --- | --- |
| 1 | [PEP 394](https://peps.python.org/pep-0394/) (`python` / `python3` / shebang guidance) | Command names and shebang expectations across Unix-like systems |
| 2 | [subprocess](https://docs.python.org/3/library/subprocess.html) (+ Security Considerations), [shlex.quote](https://docs.python.org/3/library/shlex.html#shlex.quote) | Shelling out, `shell=True`, argv lists, return codes, signals from children |
| 3 | [PEP 538](https://peps.python.org/pep-0538/) / [PEP 540](https://peps.python.org/pep-0540/) / [cmdline / UTF-8 Mode](https://docs.python.org/3/using/cmdline.html) | Locale coercion, UTF-8 Mode, `PYTHONUTF8`, stream encodings |
| 4 | [sys.exit](https://docs.python.org/3/library/sys.html#sys.exit), [argparse](https://docs.python.org/3/library/argparse.html), [signal](https://docs.python.org/3/library/signal.html) | Exit status conventions, CLI usage errors (status 2), Ctrl-C → `KeyboardInterrupt` |
| 5 | [os.environ](https://docs.python.org/3/library/os.html#os.environ), [tempfile](https://docs.python.org/3/library/tempfile.html), [pathlib](https://docs.python.org/3/library/pathlib.html), [io](https://docs.python.org/3/library/io.html) | Env empty vs unset, secure temps, path/symlink resolve, text vs bytes / newlines / buffering |
| 6 | [PEP 668](https://peps.python.org/pep-0668/) + [Ubuntu Python setup](https://ubuntu.com/developers/docs/howto/python-setup/) | Externally managed system Python; Ubuntu default `python3` |
| 7 | [Using Python on macOS](https://docs.python.org/3/using/mac.html); Apple [macOS 12.3 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-12_3-release-notes) | Apple `/usr/bin/python3` vs python.org/Homebrew; Python 2.7 removed |
| 8 | Bash side: [Bash reference](https://www.gnu.org/software/bash/manual/), [BashFAQ/105](https://mywiki.wooledge.org/BashFAQ/105) (`set -e`), this repo’s [shell portability note](./shell-linux-macos-portability.md) | What Python is *replacing* (`set -euo pipefail`, GNU/BSD utilities) |

---

## 1. Runtime availability / version floor

### Facts

| Platform | What ships | Caveat |
| --- | --- | --- |
| **Ubuntu** | `python3` is part of the default system installation; `/usr/bin/python3` → current distro default (e.g. `python3.12`) ([Ubuntu Python setup](https://ubuntu.com/developers/docs/howto/python-setup/)) | `python` may be absent unless `python-is-python3` is installed. Do not remove system `python3` (breaks OS tooling) |
| **macOS** | Python 2.7 **removed** in macOS 12.3 ([Apple 12.3 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-12_3-release-notes)). Recent macOS still expose `/usr/bin/python3` linked to an **older, incomplete** Apple/Xcode CLT build — not for general user apps ([Using Python on macOS](https://docs.python.org/3/using/mac.html)) | Operators commonly also have Homebrew / python.org / pyenv. Empirically on a 2026 Darwin research host: `env` resolved Homebrew `Python 3.14.x` while `/usr/bin/python3` reported `3.9.6` |
| **Shebang** | [PEP 394](https://peps.python.org/pep-0394/): outside venvs prefer versioned commands (`python3`); in activated venvs `python` is fine | `#!/usr/bin/env python3` follows **PATH** — pyenv/Homebrew can shadow Apple’s binary (or vice versa if PATH puts `/usr/bin` first) |

### Version-floor landmines (illustrative)

Features **not** available on Apple’s common CLT 3.9.x but easy to write by habit (see [What’s New in 3.10](https://docs.python.org/3/whatsnew/3.10.html)):

| Feature | Added | Breaks if floor is 3.9 |
| --- | --- | --- |
| `match` / `case` | 3.10 | SyntaxError |
| `X \| Y` union syntax in annotations | 3.10 | SyntaxError (unless `from __future__ import annotations` / string forms — still a policy footgun) |
| Parenthesized context managers (official) | 3.10 | Style that fails on older parsers in some cases historically; 3.10 documents official support |
| `tomllib` (stdlib TOML) | 3.11 | ImportError |
| `ExceptionGroup` / `except*` | 3.11 | Unavailable |

**Repo-relevant:** Host scripts that already `command -v python3` and fail closed (e.g. Workload Manifest / Purge helpers) assume *some* `python3` on the Host — not a specific minor. Operator machines are the weaker link.

---

## 2. Exit codes and error handling

| Bash (`set -euo pipefail`) | Python |
| --- | --- |
| Nonzero command / pipe → script aborts ([BashFAQ/105](https://mywiki.wooledge.org/BashFAQ/105) documents `set -e` quirks and exceptions) | Child nonzero is **ignored** unless `check=True` / explicit `raise` / status check ([subprocess.run](https://docs.python.org/3/library/subprocess.html)) |
| Unset variable → abort (`nounset`) | Missing env key → `KeyError` only if you index `os.environ[...]`; `os.getenv` returns `None` |
| Pipeline failure needs `pipefail` | No implicit pipelines; you compose `Popen`/`run` yourself |
| Exit status is the last failing command (with caveats) | Uncaught exception → nonzero; `sys.exit(n)` for explicit status ([sys.exit](https://docs.python.org/3/library/sys.html#sys.exit): 0 success; nonzero abnormal; Unix convention often **2** = usage/syntax, **1** = other) |

**argparse:** invalid args → print to stderr and **exit status 2** by default (`exit_on_error=True`) ([argparse](https://docs.python.org/3/library/argparse.html)).

**Signals / Ctrl-C:** default `SIGINT` handler raises `KeyboardInterrupt` ([signal](https://docs.python.org/3/library/signal.html)). That is an exception path, not Bash’s typical “130 = 128+SIGINT” shell exit. Child killed by signal: `CompletedProcess.returncode` is **`-N`** on POSIX ([subprocess](https://docs.python.org/3/library/subprocess.html)); with `shell=True`, status may be shell-mapped (e.g. `128+N`).

**Gotcha:** wrapping everything in bare `except Exception` and returning 0 loses Bash-like fail-closed behavior. Prefer `check=True`, small top-level `main()` that maps `CalledProcessError` / `SystemExit` deliberately.

---

## 3. Subprocess and shelling out

### Prefer argv lists

```python
subprocess.run(["podman", "ps", "--format", "json"], check=True, text=True, capture_output=True)
```

- Metacharacters in arguments are **not** interpreted by a shell when `shell=False` (default) ([Security Considerations](https://docs.python.org/3/library/subprocess.html#security-considerations)).
- This is the structural win over Bash word-splitting / quoting bugs ([BashPitfalls](https://mywiki.wooledge.org/BashPitfalls)).

### `shell=True` traps

- You own quoting; injection risk if any fragment is untrusted. Prefer `shlex.quote` **only** when you must build a shell string; docs still prefer list + `shell=False` ([shlex.quote](https://docs.python.org/3/library/shlex.html#shlex.quote)).
- On POSIX, `shell=True` runs **`/bin/sh`**, not Bash — so Bash-only syntax in the string is wrong ([subprocess](https://docs.python.org/3/library/subprocess.html)).
- Still needed for: shell pipelines, redirections, globs, `<( )` process substitution, or remote `ssh host 'complex shell'`.

### Env / cwd / stdio

| Concern | Behavior |
| --- | --- |
| Default env | Child inherits the process environment |
| `env={...}` | **Replaces** the environment; omit keys → child does not see them (easy to drop `PATH`, `HOME`, `SSH_AUTH_SOCK`) |
| `cwd=` | Changes child working directory only |
| `text=True` / `encoding=` | Decodes pipes as text; binary default otherwise |
| `capture_output=True` | Fills buffers — large `podman`/`terraform` output can blow memory; stream or write to files for big logs |

---

## 4. Text, bytes, locales, newlines

| Topic | Gotcha | Source |
| --- | --- | --- |
| Text vs binary | Text mode decodes/encodes; binary does not. Mixing (`Popen` bytes vs `str`) raises | [io](https://docs.python.org/3/library/io.html) |
| Locale / UTF-8 | PEP 538 coerces legacy `C` locale toward UTF-8 locales; PEP 540 UTF-8 Mode (`PYTHONUTF8=1` / `-X utf8`) forces UTF-8 for FS/IO regardless of locale. macOS already leans UTF-8 for many FS APIs | [PEP 538](https://peps.python.org/pep-0538/), [PEP 540](https://peps.python.org/pep-0540/) |
| SSH / minimal locales | Remote `C` / `POSIX` locale + tools expecting UTF-8 → surprises; coercion affects **Python** and (for PEP 538) subprocess env via `LC_CTYPE`, not magic for every binary | PEP 538 |
| Newlines | Universal newlines on read (`\n`/`\r`/`\r\n` → `\n` when `newline=None`); on write, `\n` → `os.linesep` unless `newline` set | [TextIOWrapper](https://docs.python.org/3/library/io.html) |
| Buffering / flush | `print()` does not always flush; when stdout is **not** a TTY, block buffering is common. Line buffering when interactive. Use `flush=True`, `print(..., file=sys.stderr)`, or `PYTHONUNBUFFERED=1` / `-u` for pipe/SSH progress | [io](https://docs.python.org/3/library/io.html), [cmdline `-u`](https://docs.python.org/3/using/cmdline.html) |

**Repo-relevant:** dotenv/JSON snippets already open files with `encoding="utf-8"` — good pattern; keep it when growing Python.

---

## 5. Filesystem / path / temp files

| Don’t (Bash habit) | Do (Python) | Source |
| --- | --- | --- |
| String-concat paths with `/` carelessly | `pathlib.Path` / `/` operator | [pathlib](https://docs.python.org/3/library/pathlib.html) |
| Assume `readlink -f` portability | `Path.resolve()` (symlink-aware absolute); `Path.absolute()` does **not** resolve symlinks | [pathlib.resolve](https://docs.python.org/3/library/pathlib.html) |
| `mktemp` then race-create | `tempfile.mkstemp` / `NamedTemporaryFile` / `TemporaryDirectory` (secure create; avoid deprecated `mktemp`) | [tempfile](https://docs.python.org/3/library/tempfile.html) |
| Ignore umask | `mkstemp` creates user-only files; for dirs use `mkdtemp` (user-only). Explicit `os.umask` / `os.chmod` when secrets need tighter control | [tempfile](https://docs.python.org/3/library/tempfile.html), [os.umask](https://docs.python.org/3/library/os.html#os.umask) |

**Gotcha:** `NamedTemporaryFile` defaults to delete-on-close; passing the `.name` to a subprocess that re-opens after close needs `delete=False` / `delete_on_close=False` (version-dependent API — check floor).

---

## 6. Environment variables and dotenv-like patterns

| Bash | Python |
| --- | --- |
| `export VAR=value` → child sees it | Assign `os.environ["VAR"] = "value"` (calls `putenv`) ([os.environ](https://docs.python.org/3/library/os.html#os.environ)) |
| `unset VAR` | `del os.environ["VAR"]` (calls `unsetenv`) |
| Empty vs unset matter with `set -u` and `${VAR:-}` | Empty string **is set**; missing key is unset. `os.getenv("VAR")` → `""` vs `None` |
| `os.environ` is a **cache** at import | Changes via raw `putenv`/`unsetenv` or non-Python code may not show until `os.reload_environ()` (3.14+) or process restart |

**Subprocess:** mutating `os.environ` affects later children; passing `env=` replaces wholesale — merge explicitly (`{**os.environ, "FOO": "bar"}`) when overriding one key.

**Repo-relevant:** current dotenv helpers parse in Python then emit `KEY=value` for the **shell** to eval/export. Moving “apply env” fully into Python means you must update *this* process’s `os.environ` *before* spawning `terraform`/`podman`, not only print exports for a parent Bash.

Do not read real `.env*` contents in agent/docs workflows (see ADR-0048 / `.cursorignore`); treat grammar/behavior only.

---

## 7. CLI UX parity

| Concern | Bash | Python stdlib |
| --- | --- | --- |
| Parsing | `getopts` / manual | `argparse` (richer; different UX than GNU `getopt` long-only habits) |
| `--help` | Manual or conventions | Free with `ArgumentParser` |
| Usage error exit | Often `2` by convention | **2** by default ([argparse](https://docs.python.org/3/library/argparse.html)) |
| Color / TTY | `[[ -t 1 ]]` | `sys.stdout.isatty()`; argparse may color errors — honor `NO_COLOR` / `PYTHON_COLORS` where documented |
| Progress / logs | Often stderr | Prefer **stderr** for diagnostics; keep stdout for pipe-friendly data (same ops discipline as shell) |

---

## 8. Performance / startup

- Each `python3` invocation pays interpreter startup + imports. Fine for multi-second `terraform`/`podman` flows; painful for **many tiny** SSH remote one-liners or tight loops of external CLIs.
- Bash is already the remote baseline on Hosts; a Python rewrite of a 10-line wrapper that mostly `exec`s one binary is usually a net loss.
- Prefer: keep thin Bash (or `exec` into a long-lived helper), or batch work inside one Python process instead of N `python3 -c` over SSH.

No single PEP “bans” Python for small scripts — this is an operational cost, not a language rule. Measure if hot.

---

## 9. Packaging / dependencies

| Approach | Portability hit | Notes |
| --- | --- | --- |
| **Stdlib only** | Lowest | Matches current inline snippets (`json`, `re`, `os`, `socket`, …) |
| **pip install --user / system** | High | [PEP 668](https://peps.python.org/pep-0668/) externally managed environments; Ubuntu steers to venv/apt ([Ubuntu Python setup](https://ubuntu.com/developers/docs/howto/python-setup/)) |
| **venv on Host + operator** | Medium–high | Reproducible, but must be created, activated, and present on remote Hosts / CI images |
| **Vendor single-file / zipapp** | Medium | Possible without pip on target; still need a compatible `python3` |

**Repo leaning (observation, not policy):** today’s Host/operator Python is “just `python3` + stdlib.” Growing PyPI deps without a packaging story fights Ubuntu/macOS norms.

---

## 10. Testing / linting toolchain swap

| Shell today | Python analogue | Gap |
| --- | --- | --- |
| ShellCheck + `./internals/lint-shell.sh` | **ruff** (lint/format), **mypy** (types), **pytest** (tests) | Nothing in-repo yet as a Python gate; growing `.py` without a gate repeats the “ShellCheck ≠ portability” problem in a new language |
| Bash dialect rules in CODING_STANDARDS | Version floor + stdlib-only rules | Must be written if Python expands |
| Acceptance tests already call `python3 -` | Keep; prefer importable modules over huge heredocs when logic grows | Heredocs are hard to unit-test |

**Pragmatic pattern:** Bash entrypoint (SSH, `set -euo pipefail`, operator UX) + `python3 -m propraetor_something …` or checked-in `.py` modules. Lint Bash with ShellCheck; lint Python with a separate job.

---

## 11. SSH / remote execution patterns

| Pattern | Helps | Hurts |
| --- | --- | --- |
| Remote Bash only | Always available; matches Host image | Re-hits GNU/BSD and Bash 3.2 issues on mixed targets |
| `ssh … 'python3 - <<'\''PY'\'' …'` (repo already does this) | No file install; good for JSON/dotenv/Manifest; fail closed with `command -v python3` | Requires `python3` on Host; large heredocs are untestable; startup cost per call; quoting across SSH layers is still sharp |
| Copy `.py` / module tree to Host | Testable, reviewable | Deployment/sync story; version floor must match Host |
| Assume venv on Host | Clean deps | Bootstrap + path wiring over SSH |

**Repo-relevant:** several Host paths already require `python3` (Manifest parse, Purge, database fulfill). Expanding that assumption is coherent **for Ubuntu Hosts** if images guarantee it; it is a **new** hard dependency for any macOS-only path that today is pure Bash.

---

## 12. Things that are easier in Python (brief)

Keep Bash when the script is mostly process orchestration; reach for Python when the pain is **data**:

- JSON / structured Manifests (stdlib `json`) — already used in-repo  
- Deterministic dotenv merge / validation — already used  
- Cross-platform path/date logic without GNU `date`/`sed -i` landmines  
- Retries, timeouts, HTTP (`urllib`), sockets (ephemeral port helpers already in-tree)  
- Clear exception types vs ad-hoc `|| exit 1` strings  

Python does **not** automatically erase Linux↔macOS differences in **external** CLIs you still call (`podman` on Linux Host vs absence on macOS operators, `terraform` versions, etc.).

---

## Actionable don’t / do (migration checklist)

| Don’t | Do |
| --- | --- |
| Shebang `#!/usr/bin/env python` for shared scripts | `#!/usr/bin/env python3` ([PEP 394](https://peps.python.org/pep-0394/)) |
| Assume Apple `/usr/bin/python3` ≡ Homebrew 3.12+ | Document floor; assert `sys.version_info` at startup if needed; prefer known install on operators |
| `subprocess(..., shell=True)` with untrusted bits | Argv list + `check=True`; shell only for real shell grammar |
| Ignore child exit codes (default `run`) | `check=True` or inspect `returncode` |
| Treat empty env as unset | Distinguish `None` vs `""`; document dotenv semantics |
| `print` progress on stdout in pipelines | stderr + `flush=True` / unbuffered when needed |
| Add PyPI deps “just once” on Host system Python | Stdlib, apt package, or designed venv ([PEP 668](https://peps.python.org/pep-0668/)) |
| Rewrite every 15-line wrapper | Keep Bash for thin orchestration; Python for structured logic |
| Grow `.py` with no lint/test gate | Add ruff/mypy/pytest (or chosen stack) alongside ShellCheck |

---

## Open policy choices (human decision required)

1. **Python version floor** for shared / Host / operator scripts (e.g. 3.9 to tolerate Apple CLT, vs 3.10+ / 3.12 matching Ubuntu LTS and forbidding `match` until operators upgrade).  
2. **May Host scripts assume `python3`?** (Already true in several paths — make it global or keep opt-in per script.)  
3. **Stdlib-only vs allowed third-party deps** (and if deps: venv layout, who creates it, CI image story).  
4. **macOS operator bootstrap:** require Homebrew/python.org Python, or stay compatible with Apple CLT 3.9.x, or keep operator CLIs in Bash.  
5. **Default architecture:** Bash entrypoints + Python modules vs stand-alone `#!/usr/bin/env python3` CLIs.  
6. **Exit-code convention** for Python CLIs (align with argparse’s 2 for usage; map `CalledProcessError.returncode` through vs collapse to 1).  
7. **Lint/test gate** before Python surface area grows (tooling choice + CI job).

---

## Suggested CODING_STANDARDS.md bullets

*Draft suggestions only — not applied. Distill after policy choices above.*

1. Prefer Bash for thin portable orchestration; use Python for structured parsing/merge/validation (JSON, dotenv subset, Manifest fields).  
2. Invoke **`python3` only** (shebang `#!/usr/bin/env python3` or `python3 -`); never bare `python`.  
3. Shared Python must honor the agreed **version floor**; CI should fail on older interpreters if a floor is set.  
4. Default **stdlib-only** for Host-facing automation unless an approved packaging path exists.  
5. Subprocess: argv lists, `check=True`, no `shell=True` unless shell grammar is required; then quote with `shlex.quote` and prefer `/bin/sh`-portable strings.  
6. Fail closed if `command -v python3` is missing wherever Python is required.  
7. Keep large logic in `.py` modules (importable/tested); reserve `python3 - <<'PY'` for small SSH/bootstrap snippets.  
8. Add a Python lint/test gate when the `.py` surface is no longer “occasional snippets.”

---

## Sources

- PEP 394 — The `python` Command on Unix-Like Systems: https://peps.python.org/pep-0394/  
- PEP 538 — Coercing the legacy C locale: https://peps.python.org/pep-0538/  
- PEP 540 — UTF-8 Mode: https://peps.python.org/pep-0540/  
- PEP 668 — Externally managed environments: https://peps.python.org/pep-0668/  
- Python docs: [subprocess](https://docs.python.org/3/library/subprocess.html), [shlex](https://docs.python.org/3/library/shlex.html), [sys.exit](https://docs.python.org/3/library/sys.html#sys.exit), [argparse](https://docs.python.org/3/library/argparse.html), [signal](https://docs.python.org/3/library/signal.html), [os.environ](https://docs.python.org/3/library/os.html#os.environ), [tempfile](https://docs.python.org/3/library/tempfile.html), [pathlib](https://docs.python.org/3/library/pathlib.html), [io](https://docs.python.org/3/library/io.html), [cmdline](https://docs.python.org/3/using/cmdline.html), [Using Python on macOS](https://docs.python.org/3/using/mac.html), [What’s New in 3.10](https://docs.python.org/3/whatsnew/3.10.html)  
- Ubuntu: [How to set up a development environment for Python on Ubuntu](https://ubuntu.com/developers/docs/howto/python-setup/)  
- Apple: [macOS Monterey 12.3 Release Notes](https://developer.apple.com/documentation/macos-release-notes/macos-12_3-release-notes) (Python 2.7 removed)  
- Bash / shell side: [Bash reference manual](https://www.gnu.org/software/bash/manual/), [BashFAQ/105](https://mywiki.wooledge.org/BashFAQ/105), [BashPitfalls](https://mywiki.wooledge.org/BashPitfalls), repo note [shell-linux-macos-portability.md](./shell-linux-macos-portability.md)  
- Empirical (research host, 2026-08-10): Homebrew `python3` 3.14.x on PATH vs `/usr/bin/python3` 3.9.6  
