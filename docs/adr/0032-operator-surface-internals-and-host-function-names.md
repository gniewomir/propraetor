# Operator surface vs internals; Host-local function names

Day-to-day operator surface stays at the repo root; project wiring moves under brand-neutral `internals/`. Host-local identity is named by **function**, not project brand. Provider-visible labels follow ADR-0027 (Propraetor-derived). Clean break (ADR-0018).

**Repository layout**

- **Root operator entrypoints** (high-level operations on the Environment / platform as a whole): `apply.sh`, `park.sh`, `teardown.sh`, `ssh.sh`, `database.sh` (Database admin console — ADR-0049), the unified test dispatcher `test.sh` (ADR-0036), and **`deploy.sh`** (Substrate → Deployed — ADR-0041). Diagnostics, lint, and the ensure/purge cogs are not root entrypoints — they are internals that `deploy.sh` / `ensure.sh` compose. Scoped power (one Workload, one Component) belongs as options on platform-level entrypoints later, not as separate root scripts.
- **Root declarations and docs:** `environments/` (Environment intent — ADR-0033), `docs/`, and root `*.md` stay at root. Dotdirs stay at root.
- **`internals/`:** Stack (`terraform/`), operator-machine helpers (`lib/` — not shipped beside Host Workload mirrors), Host ship surfaces (`fabric/`, `components/`, `host-scripts/`), test suites under `test/<suite>/` (ADR-0036), and a **flat** glanceable list of non-root operations (`diagnostics.sh`, `lint-*.sh`, `ensure-*.sh`, `purge-orphans.sh`, `purge-trash.sh`, … — ADR-0041). Host copy tars must not share a tree with Stack/docs/tests/operator `lib/`.
- **Rejected:** nesting internals under a project-brand directory (`prefect/`, later `propraetor/`); leaving today’s brand-named folder as both Component ship surface and junk drawer; root clutter of every runnable script; naming the Host mount or repo internals folder from the carrier metaphor.

**Amended by ADR-0041:** `deploy.sh` is the composed root Host operation; Fabric vs Components vs `host-scripts` vs operator `lib/` split as above.

**Amended by ADR-0049:** `database.sh` is a root operator entrypoint (Database admin console over SSH TCP tunnel).

**Host-local function names** (same cut as the layout move; not the Propraetor brand rename)

| Concern | Name |
|---------|------|
| Host Volume mount | `/var/lib/host-volume` |
| Platform User (Unix) | `platform` (`PLATFORM_USER`) |
| Environment slug env | `PLATFORM_ENV` |
| Host Volume systemd/IHP unit family | `host-volume.service` (and matching tmpfiles/udev) |
| SSH drop-in | `99-ssh-port.conf` |
| Edge nginx include dirs | `/etc/nginx/edge-domains`, `/etc/nginx/edge-routes` |
| Ephemeral staging | `/tmp/platform-*` |
| IHP contract gate | **Initial Host Provisioning Done** / **IHP Done** (replaces Carrier ready) |

**Provider-visible names:** Cloud Project, Propraetor Tag / Role Tag, and other account-unique resource name prefixes are Propraetor-derived per ADR-0027. Host paths/user remain **function-named**, not brand-Propraetor.

**Builds on:** ADR-0010 (Host Volume layout — paths update), ADR-0018, ADR-0019 (Environment / `--env`), ADR-0027 (amended: Host-local ≠ brand). Amended by ADR-0036 for `./test.sh` and `internals/test/`.
