# Environment declarations

Committed, Environment-scoped intent ([ADR-0033](../docs/adr/0033-environment-first-repo-layout.md); Domains: [ADR-0021](../docs/adr/0021-environment-domain-config.md); Environment Configuration: [ADR-0035](../docs/adr/0035-environment-configuration-injection.md)).

```text
environments/<cloud-slug>/domains.json
environments/<cloud-slug>/domains.override.json   # internal; gitignored (ADR-0021)
environments/<cloud-slug>/acme.json               # Edge ACME directory only (ADR-0045)
environments/<cloud-slug>/.env                    # Environment Configuration; load path (ADR-0035); never commit **/.env* (ADR-0048)
environments/<cloud-slug>/.env.example            # committed key-name teaching; Setup never reads it
environments/<cloud-slug>/.ssh/known_hosts        # Host-session TOFU; gitignored — Park forgets IP; Teardown resets (ADR-0046)
environments/<cloud-slug>/<workload-name>/          # directory = Workload (ADR-0033)
```

**Rule:** under `environments/<slug>/`, files are configuration or documentation; immediate non-hidden directories are Workload definition trees (identity = basename). Dotdirs are ignored. Workload directory internals are out of scope for ADR-0033.

**Workload Setup:** `./internals/ensure-workload.sh <workload-name> [--env <slug>]` — name only; resolves under this tree (fail closed). Batch: `./internals/ensure-workloads.sh [--env <slug>]` discovers by `manifest.json` and Setups each. Stack Apply does not run Workload Setup.

- **Cloud slug** — `test` (not Terraform workspace `default`), `prod`, `example`, … Same slug as Host naming (`propraetor-test-…`).
- **Missing `domains.json`** — that Environment has zero Domains.
- **`domains.override.json`** — if present, replaces `domains.json` for all Domain-assignment readers. Not an operator surface; Lifecycle Tests only. See ADR-0021 / `internals/test/lifecycle/README.md`.
- **`acme.json`** — Let’s Encrypt directory (`production` | `staging`) for Edge ACME. Contact email is Operator Configuration `PROPRAETOR_ACME_EMAIL` (required when this file is present). Missing file → staging, Host-derived contact. See [ADR-0045](../docs/adr/0045-environment-acme-config.md) / [ADR-0038](../docs/adr/0038-repo-root-operator-dotenv.md).

JSON shape for Domains: map of apex FQDN → `{ "names": ["@", "www", …] }` (at least one label; each A → that Environment’s Reserved IP).

JSON shape for ACME: `{ "directory": "production"|"staging" }` (no other keys).

## Environment Configuration

Non-committed key/value pairs for Workload containers ([ADR-0035](../docs/adr/0035-environment-configuration-injection.md); glossary: **Environment Configuration**).

| Artifact | Role |
|----------|------|
| `.env` | Local bag for this Environment. Optional — if absent, listed keys must come from the shell. Never commit any `**/.env*` except basename `.env.example` ([ADR-0048](../docs/adr/0048-env-star-commit-and-agent-ignore.md)). |
| `.env.example` | Committed teaching of expected key names. **Workload Setup never reads it.** |
| Manifest `environment` | Optional JSON array of key names on a Workload Manifest. Omit or `[]` ⇒ that Workload consumes none. Values never live in the Manifest. |

**Resolution (Workload Setup):** baseline from `.env` when present; current shell overrides any key; surplus bag keys not listed on that Workload are ignored; missing listed keys fail closed.

**`.env` dialect:** strict dotenv subset — `KEY=value`, `#` comments and blanks, optional double quotes. No `export`, interpolation, or multiline.

**Key names:** operator-owned for the Workload bag. Prefer not to use `PLATFORM_*`, Credential names (today `DIGITALOCEAN_TOKEN`), or Database admin credentials (`ROOT_DB_USER`, `ROOT_DB_PASSWORD`) in Manifest `environment` lists. Workload Setup does not reserve or reject other names; listing `ROOT_DB_*` on a Manifest fails closed.

**Database admin credentials** (`ROOT_DB_USER`, `ROOT_DB_PASSWORD`): may live in the same `.env` file; staged to the Database Component (ADR-0049) — not Environment Configuration, not injectable into Workloads. Mandatory for Database Setup. Documented in `.env.example`.

Provider **Credential** stays orthogonal — not part of this bag. Components do not consume the Workload Environment Configuration bag.

**Teaching example:** `environments/example/env-config` — Manifest `environment` lists `EXAMPLE_GREETING` / `EXAMPLE_MODE` (also named in `example/.env.example`); after Workload Setup with a local `.env` or shell exports, the Always-on container process environment exposes those keys via Setup-owned EnvironmentFile wiring.
