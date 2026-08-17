# Operator CLI: positionals then flags

Operator entrypoint argv had drifted into three grammars (`--env` anywhere, `--env` before positionals, `--env` must be last). Propraetor standardizes on **positionals first, then flags**; flag order among flags is free. Parsing lives in one shared Module (`internals/lib/cli.sh`: `cli_parse` / `cli_operator_parse`) — entrypoints declare a closed surface and do not hand-roll flag loops. Environment *semantics* (slug → workspace / `PLATFORM_ENV`) stay in `environment.sh`; argv peeling leaves that file. Hard cut (ADR-0018): no dual-read of old shapes.

**Shapes:** `./apply.sh --yes --env prod`; `./internals/ensure-workload.sh <name> [--env <slug>]`; `./test.sh <suite> [<case-selector>] [--from <token>] [--verbose] [--env <slug>]`. Passthrough entrypoints with no named positionals (`./ssh.sh`) may declare `rest:` — known flags are peeled from anywhere; remaining tokens forward (so remote argv can start with `-`).

**Amended by ADR-0056:** `./test.sh` gains `--from <token>` (Acceptance/Lifecycle); mutually exclusive with the case selector.

**Considered:** POSIX `getopts` (options-first — fights this grammar); GNU `getopt` (not portable on macOS); flags-anywhere forever; a larger define/usage DSL. Rejected for portability, footguns, or premature surface area.
