# HTTPS readiness is operator Route + certificate material, not Setup projection

**Historical Setup/ACME TLS-shell projection slice superseded by [ADR-0022](0022-operator-owned-routes.md)**. Body below is the rewritten current contract — not a dead ADR.

Workload Setup must not block on certificate issuance — DNS is out of band and happy-path ACME is usually seconds to a couple of minutes, but mispointed DNS makes wait time unbounded. Operator-authored **Routes** may reference certificate paths; whether HTTPS answers is a readiness/Acceptance concern once PEMs exist on the Host Volume, not a Workload Setup success criterion. After ACME writes usable PEMs, Edge ACME **reloads** the front door without rewriting Route files so existing fulfilled Routes can use new material (ADR-0015 / ADR-0022). Intent **stop** / **trash** means Edge Component Setup must not fulfill that Workload’s Routes (no Propraetor-managed 503 shells — ADR-0014 / ADR-0022 / ADR-0040).

**Non-blocking Setup over Setup-waits-for-cert:** keeps Workload Setup deterministic when DNS or CAA is wrong.

**Reload-without-Route-rewrite over ACME reprojecting Manifest shells:** preserves operator-owned Route bytes.
