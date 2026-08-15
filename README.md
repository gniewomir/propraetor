# Propraetor

Reproducible Environments on a vertically scaled cloud Hosts — Podman pods and containers as first-class citizens, without full orchestration. Ready to graduate to dedicated infrastructure with thin adaptation.

Domain language: [`CONTEXT.md`](CONTEXT.md). Decisions: [`docs/adr/`](docs/adr/).

These principles guide Propraetor's development. Propraetor is pre-stability, and the current implementation does not yet satisfy all of them.

## Principles

### Own the foundation; preserve the exit

Prefer infrastructure we understand and control over opaque app-platform dependencies. Keep the Propraetor-specific surface thin and Workload configuration portable, so changing provider or graduating a Workload requires adaptation rather than reinvention.

### Automate repetition; preserve meaningful decisions

Automate work that would otherwise be repeated across projects. Keep choices that materially shape infrastructure or Workload behavior explicit, inspectable, and under operator control.

### Declare intent; expose the mechanism

Propraetor declarations describe desired outcomes, and applying one repeatedly should produce the same managed outcome. Except for a minimal Manifest, Workload configuration remains in the underlying software's native formats rather than being replaced by Propraetor-specific abstractions. Propraetor coordinates tools without concealing their operation behind hidden assumptions or implicit behavior.

### Prefer secure simplicity over generality

Choose opinionated, secure operator defaults and the smallest operational model suitable for a solo operator.

### Make infrastructure reproducible

The repository and its explicit inputs should be sufficient to recreate equivalent infrastructure from scratch, without undocumented manual steps or knowledge held only by the operator.

### Make promises executable

Propraetor states its contracts in documentation and verifies their observable behavior with tests. Provider implementations may differ internally, but must satisfy the same Acceptance and Lifecycle behavior.

### Scale the Host; graduate the exceptions

Make Host capacity changes routine and low-disruption. Prefer vertical scaling while the shared Host remains sufficient; when a Workload outgrows that model, move it to dedicated infrastructure rather than expanding Propraetor into a general-purpose orchestrator.

## Credentials

Repo-root `.env` (see `.env.example`) baselines **Provider Credential** and **Operator Configuration**; non-empty process-environment values win ([ADR-0038](docs/adr/0038-repo-root-operator-dotenv.md)). Never commit any `**/.env*` except basename `.env.example` ([ADR-0048](docs/adr/0048-env-star-commit-and-agent-ignore.md)).

```bash
# .env (or export in the shell)
DIGITALOCEAN_TOKEN=…
PROPRAETOR_PUBLIC_KEY_PATH=~/.ssh/your_key.pub
PROPRAETOR_PRIVATE_KEY_PATH=~/.ssh/your_key
```

Apply requires both key paths (public → IHP root login). Park/Teardown need the token only. Host SSH helpers need the private path ([ADR-0037](docs/adr/0037-host-login-via-ihp-not-account-ssh-key.md)).
## Environments

Every operator script takes an optional `--env <slug>`.

- Omit it (or pass `test` / `default`) → **test** Environment
- Any other slug (e.g. `prod`) → that Environment, only when you ask for it

Safe by default: nothing touches a non-test Environment unless you pass `--env` explicitly. Details: [ADR-0019](docs/adr/0019-environments.md).

Layout, Workload trees (Manifest + Binding + Artifact), Domains, and **Environment Configuration** (`.env` load path, committed `.env.example`, Binding remap × Requires): [`environments/README.md`](environments/README.md), [ADR-0035](docs/adr/0035-environment-configuration-injection.md), [ADR-0053](docs/adr/0053-workload-provides-requires-binding.md); never-commit rule: [ADR-0048](docs/adr/0048-env-star-commit-and-agent-ignore.md).

## Durables

**Durables** are the Cloud Project, Reserved IP, Host Volume, **Domain** (provider DNS zone plus Stack-authored A records → Reserved IP), and their preserved Cloud Project relationships. They survive **Park**. **Recreatables** are the Host and its Applied-only companions and relationships; Park removes them and Apply restores them. Durables may continue to incur charges while Parked. **Teardown** removes the complete Stack.

Domains are optional (**0..N** per Environment). Declare them in committed `environments/<cloud-slug>/domains.json` (map of apex FQDN → `{ "names": ["@", "www", …] }`). Missing file = no Domains. The Stack loads the file for the current Environment (workspace / `--env`); no `TF_VAR_domains`. Registrar purchase and NS delegation stay **out of band**. New Domains: [add a Domain](docs/runbooks/domain-durable-add.md). Adopting an existing provider zone: [domain Durable import](docs/runbooks/domain-durable-import.md). Declaration mechanism: [ADR-0021](docs/adr/0021-environment-domain-config.md).

## Operations

Day-to-day operator surface (Environment lifecycle):

| Script | What it does |
|--------|----------------|
| `./apply.sh [--yes] [--env <slug>]` | Bring the Stack up (or converge it). Interactive plan by default; `--yes` for automation. |
| `./deploy.sh [--env <slug>]` | Take a Substrate Host to **Deployed** (Fabric → Mirror → Orphan Reap → Components `pre-workloads` → Workloads → Components `post-workloads`). Does not run Apply. |
| `./park.sh [--env <slug>]` | Tear down the Host and other non-durables; keep Durables. For development and other non-production Environments — so you are not billed for a Host you are not using. Confirm by typing `park`. |
| `./teardown.sh [--env <slug>]` | Full wipe, including Durables. Stops Durable billing. Confirm by typing `teardown`. |
| `./ssh.sh [--env <slug>] [ssh args…]` | SSH to the Host (root @ Reserved IP; Stack SSH port from `internals/lib/ssh.sh` — not raw `:22` after ADR-0030 cutover). |
| `./database.sh [read or write] [--env <slug>]` | Interactive Postgres console as Database admin (`ROOT_DB_*`) over an SSH TCP tunnel. Default `read` sets soft `default_transaction_read_only` (bypassable); `write` omits it. |

Tests: unified `./test.sh <suite>` (Acceptance, Lifecycle, Unit) — [docs/agents/testing.md](docs/agents/testing.md), [ADR-0036](docs/adr/0036-unified-test-entrypoint.md). Everything else lives under `internals/` (flat glanceable list): diagnostics, lint, `ensure.sh` (Deploy ladder), ensure-fabric, ensure-mirror, ensure-components, ensure-workload(s), purge-orphans, Stack, Fabric, Components, and helpers. Same `--env` rule for Environment-scoped entrypoints. Layout and Host-local function names: [ADR-0032](docs/adr/0032-operator-surface-internals-and-host-function-names.md).

**Cutover note:** Host Volume mount, Platform User, units, and Edge nginx paths renamed in ADR-0032 — already-Applied Environments need Host recreation (Park/Apply or equivalent); there is no dual-read of old Host paths.

Further reading: [ADR-0025](docs/adr/0025-lifecycle-convergence-by-structural-class.md) (lifecycle convergence), [ADR-0020](docs/adr/0020-domain-durable.md) (Domain Durable), [ADR-0021](docs/adr/0021-environment-domain-config.md) (Environment Domain config), [ADR-0050](docs/adr/0050-platform-journal.md) (Platform journal), [`docs/runbooks/domain-durable-add.md`](docs/runbooks/domain-durable-add.md), [`docs/runbooks/domain-durable-import.md`](docs/runbooks/domain-durable-import.md), [`docs/runbooks/platform-journal.md`](docs/runbooks/platform-journal.md) (read unit/Workload streams), [`docs/agents/testing.md`](docs/agents/testing.md) (test suites).
