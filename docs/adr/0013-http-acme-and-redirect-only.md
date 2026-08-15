# HTTP on the Edge is ACME and HTTPS redirect only

Once a name has a certificate, :80 serves HTTP-01 challenges and redirects all other HTTP requests to HTTPS. The Edge never proxies a Workload over cleartext. Before the certificate exists, :80 may still serve ACME for that name; Workload HTTPS waits on operator-authored Routes plus PEMs (ADR-0012). Cleartext Workload traffic is never published onto :80; Intent **stop** means Edge Component Setup does not fulfill that Workload’s Routes (Edge default miss — ADR-0014 / ADR-0022 / ADR-0040), not a Propraetor-managed 503.

**ACME + redirect over cleartext Workload serving:** preserves issuance/renewal and human `http://` links without weakening the TLS front door.
