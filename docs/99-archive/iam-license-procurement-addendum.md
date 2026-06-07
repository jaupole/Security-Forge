> 🗄️ **ARCHIVED 2026-06-07 — local-first / build-era document.**
> This describes the original Docker Desktop / WSL2 / `secforge.local` build, **not** the current
> bare-metal `secforge-prod` deployment. Kept for history only. For current state see `PLAN.md`,
> `docs/01-architecture/`, and `docs/06-reference/operator-backlog.md` (archive index: `docs/99-archive/README.md`).

# Addendum: License & Procurement

*Append this to the IAM Architecture report between the Threat Model section and the Final Note on Hedging.*

---

## License & Procurement — What's Actually Free, What's Not, and What It Costs

The 2023–2025 wave of license migrations (HashiCorp, Redis, Elastic, MongoDB, Sentry) means "open source" needs to be parsed carefully. Several components in this stack require commercial licenses for the FIPS-validated builds that CMMC actually requires. Treat this as the procurement-and-legal companion to the architecture above.

### License-by-license breakdown

| Component | License | OSI-approved OSS? | Commercial obligation in your use case? |
|---|---|---|---|
| Keycloak | Apache 2.0 | Yes | None — fully free. Red Hat/Phase Two builds are paid support, same code |
| SpiceDB | Apache 2.0 | Yes | None — AuthZed Enterprise is optional ops features |
| SPIRE/SPIFFE | Apache 2.0 | Yes | None |
| Istio/Envoy | Apache 2.0 | Yes | None — but FIPS-validated Envoy comes from Tetrate/Solo.io/AWS |
| OpenFGA, Cerbos, Cedar, Ory | Apache 2.0 | Yes | None |
| Postgres | PostgreSQL License (BSD-style) | Yes | None |
| Kubernetes, Sigstore, Syft, Trivy, Grype, gitleaks, Semgrep CE | Apache 2.0 / equivalent | Yes | None |
| Wazuh (SIEM) | AGPL 3.0 | Yes | None for internal use |
| **Teleport Community** | **AGPL 3.0** | Yes | Internal use is fine; **FIPS endpoints require Enterprise** |
| **HashiCorp Vault** | **BSL 1.1** | **No** | Internal use is fine; **FIPS build requires Enterprise** |
| **Redis 7.4+** | **RSALv2 / SSPLv1** | **No** | Use **Valkey (BSD-3-Clause)** instead — drop-in replacement |
| Zitadel | AGPL 3.0 (relicensed 2025) | Yes | Watch for SaaS-redistribution scenarios |
| Authentik core | MIT | Yes | Enterprise tier for advanced features |
| FusionAuth | Proprietary | No | Free tier exists; SAML/SCIM/threat detection are paid |
| Permify | Apache 2.0 (acquired by FusionAuth Nov 2025) | Yes | Watch for post-acquisition license changes |

### Forks worth knowing about

- **Valkey** (Linux Foundation, BSD-3-Clause) replaces Redis. AWS, Google Cloud, Oracle have migrated. Use Valkey for the BFF session store.
- **OpenBao** (Linux Foundation, MPL 2.0, CNCF Sandbox) replaces Vault. Not yet FIPS-validated as of April 2026 — track the roadmap. Viable for non-CUI environments now.
- **OpenSearch** (Apache 2.0) replaces Elasticsearch if you need a SIEM data tier.

### Components requiring commercial licenses for CMMC/FIPS

These are the line items you cannot avoid if you commit to CMMC Level 2:

1. **Teleport Enterprise** — for FIPS 140-2 endpoints. Community edition (AGPL) does not include FIPS builds.
2. **Vault Enterprise (FIPS 140-2 Inside)** — for HSM auto-unseal and FIPS-validated cryptography. *Or* use OpenBao for non-CUI environments and accept that FIPS validation is a 2027 timeline question.
3. **Red Hat build of Keycloak (RHBK)** — optional but recommended; you get vendor-supported BCFIPS configuration, predictable patching, and a defensible "supported version" answer for auditors. Phase Two is a credible alternative.
4. **FIPS-validated Envoy** — Tetrate Service Bridge, Solo.io Gloo Mesh, or AWS App Mesh ship FIPS-validated Envoy builds. Required for the data plane to be in CMMC scope.
5. **HSM service or hardware** — cloud HSM (AWS CloudHSM, Azure Managed HSM, GCP Cloud HSM) or on-prem (Thales Luna, YubiHSM 2). Not optional for CMMC-grade key custody.
6. **Hardware FIDO2 keys** — YubiKey 5 FIPS series (or Feitian FIPS) for every privileged user, two each for redundancy.

### Realistic annual cost envelope (USD, April 2026 estimates)

These are order-of-magnitude figures based on public list pricing and typical negotiated rates for a ~10-person engineering org with ~50 privileged users and 100k end users on the trajectory you described. Real numbers will vary 30–50% based on negotiation, region, and bundling.

| Line item | Tier / scope | Annual cost (USD) |
|---|---|---|
| Teleport Enterprise | ~50 privileged users, FIPS, session recording | $30k–$60k |
| Vault Enterprise (FIPS) | Standard tier, 1 cluster, HSM auto-unseal | $40k–$120k |
| Red Hat build of Keycloak | Standard subscription, 1 cluster | $15k–$40k (often bundled with OpenShift) |
| FIPS-validated Envoy distribution | Tetrate or Solo.io, single cluster | $25k–$75k |
| Cloud HSM service | AWS CloudHSM (1 HSM, 1 region, 24/7) | ~$18k (~$1.45/hr × 8760h) |
| Cloud HSM (HA) | 2 HSMs across AZs | ~$36k |
| YubiKey 5 FIPS | 50 users × 2 keys × ~$75 | $7.5k (one-time, refresh every 3–4 yr) |
| SIEM (if not Wazuh) | Splunk Cloud / Elastic / Sumo | $50k–$200k (highly variable) |
| MaxMind GeoIP2 | Standard subscription | $1k–$3k |
| **Subtotal — required commercial line items** | | **~$165k–$360k/year** |
| **Optional but commonly bundled** | | |
| AuthZed Enterprise (SpiceDB) | Multi-region ops features | $30k–$80k |
| Snyk / SCA tooling | Team of 10 | $10k–$25k |
| **Total realistic envelope** | | **~$200k–$465k/year** |

### Cost-reduction levers if the budget is tight

If the CFO blanches at the upper end of the range, the legitimate ways to compress the number:

1. **Defer FIPS-validated Envoy** until you're actually selling to a CMMC-scope customer. Run Envoy from upstream until then; the gap is months, not architecture-years.
2. **Use OpenBao instead of Vault Enterprise** for non-CUI environments. Reserve Vault Enterprise for the production CUI cluster only — saves ~60% on Vault spend.
3. **Single-region cloud HSM** at launch. HA HSM is a real CMMC concern but you can defer the second HSM until you have a customer demanding multi-region.
4. **Wazuh as SIEM** is genuinely production-quality at this scale and saves $50k–$200k/year vs commercial SIEMs. The cost is operational complexity.
5. **Phase Two managed Keycloak** can be cheaper than Red Hat for small clusters and includes the SCIM 2.0 SPI by default.
6. **Defer Teleport Enterprise** until your privileged user count or audit obligations require session recording. Community AGPL is fully usable for internal access if FIPS is not yet a contract requirement.

The compressed envelope with these levers is roughly **$80k–$150k/year** for the commercial line items, with a clear upgrade path as customer demand and audit scope expand.

### Procurement and legal posture

Three things to settle before signing the first commercial contract:

1. **License audit cadence.** Add quarterly review of every dependency's license to your supply-chain process. The 2023–2025 wave proved that license terms are not stable assumptions. Treat license changes the same way you treat security advisories.
2. **Fork-readiness.** For each commercial-only component, document the OSS fork or alternative (OpenBao for Vault, Valkey for Redis, OpenSearch for Elasticsearch). You don't need to migrate; you need to know you *could* if licensing posture changes again.
3. **Right-to-audit clauses.** SOC 2 / ISO 27001 / CMMC all require evidence that your subprocessors meet equivalent controls. Negotiate right-to-audit, breach notification timelines (≤72 hours for GDPR-overlap), and SOC 2 Type 2 report delivery into every commercial contract.
