# Workload Manifest declares Intent; operator Routes are Declarations, not projected

**Historical projection slice superseded by [ADR-0022](0022-operator-owned-routes.md)** (Manifest produces Routes). Body below is the rewritten current contract — not a dead ADR.

A **Workload Manifest** is the source of truth for that Workload’s **Workload Intent** (ADR-0014 / ADR-0017); thin wire shape, required **Source**, and authored units: ADR-0024 / ADR-0053. It does not claim DNS names or feed ACME (want-list SoT: ADR-0023). **Routes** are Workload-offered location-context fragments under **Provides**, attached to Domain fronts only via **Binding**; Edge Component Setup gathers Intent-**run** bound Declarations into Edge-owned storage (ADR-0022 / ADR-0028 / ADR-0053). Propraetor does not generate Edge shells or Manifest **interior** splicing. ACME obtains one certificate per want-list name (HTTP-01); DNS for Domain-declared names is Stack-managed (ADR-0020 / ADR-0021). Domain owns names and certificate material; a Workload uses them via Binding → Routes.

**Operator-authored full Routes over generate-shell + optional interior:** Propraetor stops owning Edge HTTP behaviour for Workloads; native Edge config stays the Workload HTTP language.

**Enumerated Domain FQDNs + HTTP-01 over wildcards / DNS-01:** matches multiple domains and subdomains without DNS provider credentials on the Host (ADR-0023).

**Amended by ADR-0053:** Provides / Requires / Binding replace Workload-tree `routes/` FQDN-as-filename SoT and Manifest-owned env/db selection.
