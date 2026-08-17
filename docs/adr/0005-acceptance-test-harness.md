# Acceptance Test harness

Operator checks of an applied Stack are **Acceptance Tests**: the Acceptance suite runner re-converges to **Deployed** via **Deploy** before each numeric-prefixed capability-slice script (fail-fast; optional single-slice selector or `--from` remainder) — ADR-0042 / ADR-0056. They require a live Applied Stack (Host present) and are **non-destructive** to Stack lifecycle — they must not Park or Teardown. Stack lifecycle checks are **Lifecycle Tests**, a separate opt-in suite (ADR-0036 / ADR-0042). Invocation and suite layout: ADR-0036 (`./test.sh acceptance`). Prefix encoding: ADR-0056.

**Why this shape:** a monolith inside the Stack directory hid the extension path and mixed unrelated contracts. Filename sort encodes dependency order without a manifest; subprocesses stop shell state leaking between slices. Deploy-before-each-case (not fixture-once) is the Host isolation boundary — ADR-0042. Alternatives considered for harness shape: self-contained cases (duplicated terraform/jq setup), sourced-in-runner cases (shared `set +e` hazards), and an explicit order file (second place to edit on every add).

**Amended by ADR-0056:** four-digit prefixes; `--from` remainder-of-suite.
