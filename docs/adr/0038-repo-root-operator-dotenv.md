# Repo-root `.env` baselines Provider Credential and Operator Configuration

Operators need a durable local baseline for **Provider Credential** and **Operator Configuration** without exporting everything by hand each shell, without committing secrets, and without conflating that with **Environment Configuration** (`environments/<slug>/.env`, ADR-0035). Propraetor loads an optional **repo-root** `.env` as baseline; a non-empty process-environment value wins per key. Committed root `.env.example` documents the allowlist. Same strict dotenv subset as ADR-0035 (`KEY=value`, `#`/blanks, optional double quotes; no `export`, interpolation, or multiline). Missing root `.env` is fine (shell/CI only). Never-commit / agent-ignore for any `**/.env*` (sole exception: basename `.env.example`) is [ADR-0048](0048-env-star-commit-and-agent-ignore.md) — load path remains exact repo-root `.env`.

**Allowlist (fail closed):** only `DIGITALOCEAN_TOKEN`, `PROPRAETOR_PUBLIC_KEY_PATH`, `PROPRAETOR_PRIVATE_KEY_PATH`, `PROPRAETOR_ACME_EMAIL`, and `PROPRAETOR_ENVIRONMENTS_ROOT` (ADR-0051). Unknown keys, legacy names (`SSH_IDENTITY`, `VERIFY_SSH_IDENTITY`, `TF_VAR_DIGITALOCEAN_PUBLIC_KEY`, …), and `TF_VAR_host_root_ssh_public_key` in the file are errors — Apply derives pubkey content from the public path (ADR-0037). Empty file values are unset. Operator Configuration paths must be absolute or `~/…` (leading `~/` expands to `$HOME` after load); other relative paths fail closed. `PROPRAETOR_ACME_EMAIL` is optional at load; when an Environment has committed ACME configuration (`acme.json`), ACME staging fail-closes if it is missing or empty (ADR-0045). `PROPRAETOR_ENVIRONMENTS_ROOT` is optional at load; when set it must name an existing directory and fully replaces repo `environments/` for Environment-tree readers (ADR-0051).

**Amended by ADR-0051:** Environments root Operator Configuration key on the allowlist.

**Who loads:** a shared helper at the start of operator entrypoints that gate on Provider Credential or Operator Configuration (root Apply/Park/Teardown/ssh/`test.sh` acceptance & lifecycle; Host-facing ensure-components, ensure-workload, ensure-workloads, purge-trash, diagnostics). Not loaded for bare Terraform in the Stack dir. Retires docs-only `internals/terraform/.env.dist` (ADR-0018).

## Considered

Shell-only forever; folding Provider Credential into Environment Configuration; open/surplus keys in root `.env`; relative-to-cwd or repo-root relative paths; auto-loading from raw Terraform. Rejected — wrong bag, silent typos, or cwd footguns.
