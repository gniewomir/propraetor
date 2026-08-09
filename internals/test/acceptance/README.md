# Acceptance Tests

Executable checks that the live Stack’s **Deployed** Host matches the intended contract. Requires an Applied Stack and Credentials. Assert observable outcomes only — not Terraform internals.

**Entrypoint:** `./test.sh acceptance` — see [docs/agents/testing.md](../../../docs/agents/testing.md) (ADR-0036). Suite baselines: [ADR-0042](../../../docs/adr/0042-suite-baselines-and-test-isolation.md).

**Non-destructive (Stack lifecycle):** must not Park or Teardown. Host-local mutation is allowed under ADR-0042 rules below. Stack lifecycle (Park, Apply-after-Park, Teardown) is Lifecycle Tests — see `../lifecycle/README.md`.

## Suite baseline (ADR-0042)

- Baseline between cases: **Deployed**.
- Runner re-converges via **Deploy** (`./internals/ensure.sh` / `./deploy.sh`) **before each case**. Failed-case Host artifacts remain until the next baseline.
- Cases restore Environment SoT / Intent to committed truth before exit (remove fixtures or leave Intent only when deliberately testing **trash** + Purge). Runner owns Host convergence.
- After each baseline Deploy, the runner snapshots `environments/<slug>/` (excluding `.ssh/`) and asserts the tree is identical after the case (covers gitignored `.env` / `.env.override` and leftover fixtures).
- **Host Volume `data/`:** do not destroy bytes except as expressed operator Intent (Environment absence / Intent **trash** → Orphan Reap / Purge via Deploy). Case-owned cleanup only for case-created durable residue that would **survive** the next Deploy; register those paths for tracked **G**. No peer-pollution cleanup.
- **`test` only** for Environment fixtures / SoT mutation (track helpers, Intent-trash / Purge / Orphan Reap fixture paths).
- Non-**test**: type exact `diagnose <slug>` (slug matches `--env`); Environment SoT stays at committed `HEAD`; fixture-class cases skipped (full suite) or refused (explicit selector); baseline Deploy aborts if `environments/<slug>/` is dirty vs `HEAD`; case-owned Host Volume `data/` probes still allowed; Deploy still runs.

## Run

From the repo root:

```bash
./test.sh acceptance                 # all Acceptance Tests on the test Environment (default)
./test.sh acceptance 70-podman       # one slice (substring match on the filename)
./test.sh acceptance --env test      # same Environment as omitting --env (`default` also aliases here)
./test.sh acceptance --env prod      # diagnostic; prompts for exact 'diagnose prod'
./test.sh acceptance 70-podman --env test
```

**Environment (ADR-0019 / ADR-0042):** no `--env` → **test** (workspace `default`). `--env test` / `--env default` are aliases. Any other slug requires explicit `--env <slug>` and typed `diagnose <slug>`. Positionals first, then flags; flag order free (ADR-0039).

Requires Provider Credential and Operator Configuration private key path (root `.env` or process environment — ADR-0038).

## Add a new Acceptance Test

1. Pick the next free numeric prefix (gaps of 10 are intentional so you can insert).
2. Add `NN-short-name.sh` — one capability / contract slice per file.
3. Start from `set -euo pipefail`, source `lib.sh`, and use `pass` / `fail`.
4. Assume fixture env from the runner (`IP`, provider-observed `RESERVED_IP_JSON` / `HOST_JSON`) and use `do_api_get` for other provider outcomes.
5. Restore Environment SoT before exit. Ephemeral fixture Workloads: `acceptance_wl_track` (remove on cleanup) — that is what live cases use today. Environment Configuration fixtures: write `environments/<slug>/.env.override` only (never mutate live `.env`); remove the override on EXIT. Mutating a **committed** Environment path (e.g. editing tracked `domains.json`): also `acceptance_sot_track` so EXIT restores from git HEAD — opt-in; no live case does this yet. Register survive-Deploy `data/` creations with `acceptance_data_track`. One EXIT trap: `acceptance_wl_cleanup` (fixtures + SoT restore + tracked `data/` cleanup/**G**). The runner also asserts the Environment tree is unchanged after the case (minus `.ssh/`). Do not clean “whatever previous cases left.”
6. Keep the script focused on external behavior. The runner discovers `[0-9]*.sh` automatically — no registry edit.
7. Do not call `./park.sh`, `./teardown.sh`, or otherwise remove the Host / Durables.

Non-case files in this directory (`lib.sh`, `run.sh`, `baseline.sh`, this README) are not executed as cases.

## Layout

| Path | Role |
|------|------|
| `run.sh` | Suite runner (via `./test.sh acceptance`) |
| `baseline.sh` | Suite Deploy / diagnose helpers (ADR-0042) |
| `lib.sh` | Shared `pass` / `fail` / probes / isolation track+cleanup |
| `NN-*.sh` | Acceptance Tests (sort order = run order) |
| `../lifecycle/` | Lifecycle Test suite |
| `../unit/` | Unit Test suite runner |
