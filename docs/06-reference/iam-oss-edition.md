# IAM Architecture — Open-Source Edition (No CMMC, Compliance-Ready)

**Companion to the full IAM Architecture report.** This document specifies the same architecture using only open-source components, with explicit upgrade paths for each layer when CMMC, FedRAMP, or regulated-industry customers enter scope. The goal: spend ~$0 on software today, and when a contract demands compliance, swap components without changing protocols, APIs, or application code.

**Design principle.** Every commercial component in the original report is replaced by an OSS equivalent that speaks the same protocol or API. Upgrading is a deployment change, not a rewrite.

---

## At-a-glance comparison

| Layer | Original (CMMC-ready) | OSS Edition (this doc) | Upgrade path |
|---|---|---|---|
| Identity Provider | Red Hat build of Keycloak (BC-FIPS) | **Keycloak upstream** (Apache 2.0) | Switch container image to RHBK; enable FIPS mode |
| Authorization | SpiceDB + AuthZed Enterprise option | **SpiceDB upstream** (Apache 2.0) | Add AuthZed Enterprise license; same wire protocol |
| Token strategy | OAuth 2.1 + DPoP + PAR | **Identical** — protocol decisions, not products | No change |
| Auth factors | YubiKey 5 FIPS + passkeys | **Platform passkeys + any FIDO2 key** | Replace user-issued keys with FIPS series |
| Multi-tenant | Keycloak realms | **Identical** | No change |
| Session store | Redis Enterprise/standard | **Valkey** (BSD-3-Clause, Linux Foundation fork) | None needed; Valkey is the preferred long-term answer |
| BFF / SPA security | Same pattern | **Identical** | No change |
| Workload identity | SPIRE | **Identical** (already OSS, CNCF graduated) | No change |
| Service mesh | Istio + FIPS-Envoy distribution | **Istio + upstream Envoy** | Swap to Tetrate / Solo.io / AWS FIPS Envoy distribution |
| Privileged access | Teleport Enterprise | **Teleport Community** (AGPL 3.0) | License upgrade; same binaries |
| Secrets / dynamic creds | Vault Enterprise FIPS | **OpenBao** (Linux Foundation, MPL 2.0, CNCF Sandbox) | API-compatible swap to Vault Enterprise |
| Key custody | Hardware HSM (CMVP-validated) | **Cloud KMS** (AWS KMS / Azure Key Vault / GCP KMS standard tier) | Migrate to CloudHSM tier or on-prem Thales/YubiHSM |
| Database | Postgres | **Identical** | No change |
| SIEM | Splunk/Elastic Cloud | **Wazuh** (AGPL 3.0) | Add Splunk/Elastic alongside; Wazuh stays as agent fleet |
| Image / supply chain | Sigstore, Syft, Trivy, Grype, gitleaks, Semgrep CE | **Identical** | No change |

**Total software cost: $0.** Infrastructure costs only (Kubernetes, Postgres, KMS key operations, hardware FIDO2 keys for admins).

---

## A. Identity Provider — Keycloak Community

**Choice: Keycloak upstream (Apache 2.0), latest stable.** Same project, same code, same protocols as the Red Hat build. The only thing missing is the BC-FIPS provider configuration and Red Hat's productized patching cadence.

### Hardening that still applies (and is free)
- Run on any minimal base image — UBI 9 minimal, Ubuntu 24.04 minimal, or Alpine. Image scanning via Trivy in CI.
- **Database**: Postgres 16 with TLS verify-full, separate user with minimum privileges, PITR enabled.
- **Cache**: Infinispan distributed cache with `cache-stack=jdbc-ping`. Three replicas, anti-affinity across AZs.
- **Signing keys**: stored in Cloud KMS via PKCS#11 (AWS KMS, Azure Key Vault, GCP KMS all support this). Rotate every 90 days with overlap.
- **Admin console**: separate hostname, separate ingress, network-policy restricted to admin VPN/ZTNA/Tailscale.
- **Disable**: implicit flow, ROPC, unencrypted SAML, password grant. **Enforce** PKCE on all public clients.
- **Realm config**: short access token lifespan (5–10 min), refresh token rotation with reuse detection, phishing-resistant MFA on admin realm.
- **PodSecurity admission**: `restricted` profile, non-root, read-only root filesystem.

### What you give up vs RHBK
- No FIPS 140-validated crypto provider.
- No vendor SLA on patches (you watch GitHub advisories yourself, and you do — subscribe to `keycloak/keycloak` security advisories).
- You are the support team if something breaks at 2am.

### What stays identical
- All protocols (OIDC, OAuth 2.1, SAML 2.0, FAPI 2.0).
- Realm configuration format (export/import works to RHBK).
- The Operator, Helm chart, and Kubernetes deployment patterns.
- Event listener SPI for SIEM integration.

### Upgrade trigger and procedure
**Trigger**: any of — federal contract opportunity; CMMC mandate in customer questionnaire; FIPS 140 listed as a requirement; healthcare or financial customer requiring SOC 2 + a FIPS attestation.

**Procedure** (estimated 1–2 weeks):
1. Switch Keycloak container image to `registry.redhat.io/rhbk/keycloak-rhel9` at the matching minor version.
2. Switch base image to RHEL 9 / UBI 9 with `fips=1` kernel flag.
3. Add BC-FIPS provider jars and configure `java.security` for FIPS mode.
4. Migrate keystores to BCFKS format.
5. Re-issue customer-facing realm signing keys via the FIPS provider (with overlap window so existing tokens validate).
6. Update password policy minimums to FIPS-mode requirement (14 chars).

No realm export/import is needed. No client config changes. No application code changes.

### Optional now: SCIM 2.0 server
Vanilla Keycloak does not ship a SCIM 2.0 server. Two free options:
- The community **`keycloak-scim`** SPI (Phase Two maintained, Apache 2.0).
- Build your own SCIM endpoint as a thin service that calls Keycloak's Admin REST API (acceptable for low-volume tenants).

When upgrading to RHBK, the SCIM SPI works identically.

---

## B. Authorization — SpiceDB OSS

**Choice: SpiceDB upstream (Apache 2.0), with Postgres datastore.** This is already the recommended choice — AuthZed Enterprise is purely operational features for multi-region.

### What you have for free
- Full Zanzibar consistency model with ZedTokens.
- gRPC API with mTLS.
- All schema features (unions, intersections, exclusions, CAVEATs).
- `LookupResources` and `LookupSubjects` for "list everything I can see" queries.
- Structured logs streamable to SIEM.

### What AuthZed Enterprise adds (defer until needed)
- Cluster dispatch optimization for multi-region.
- Pre-shared key rotation tooling.
- Audit log shipping integrations.
- Vendor support SLA.

### Upgrade trigger
**Trigger**: multi-region deployment; contractual audit-log retention SLA; first enterprise customer with $100k+ ACV demanding vendor support.

**Procedure** (estimated 1 week):
1. AuthZed Enterprise license issued.
2. Switch container image; same Postgres datastore, same schema.
3. No application code changes; gRPC API is identical.

---

## C. Token Strategy — Identical to original

This layer has no commercial dependency. Every recommendation in the original report applies:
- OAuth 2.1 baseline with PAR (RFC 9126), JAR (RFC 9101), PKCE.
- DPoP-bound access and refresh tokens (RFC 9449).
- Refresh token rotation with reuse detection.
- BFF pattern for browser clients; SPA never holds tokens.
- mTLS-bound tokens for service-to-service via SPIFFE.
- RP-Initiated, Front-Channel, and Back-Channel logout (all three).

Keycloak community supports all of the above. No upgrade path needed.

---

## D. Authentication Factors — OSS Edition

### Recommended day-one mix
1. **Platform passkeys** (Touch ID, Windows Hello, Android) — free, every modern device has them, AAL2-compliant per NIST SP 800-63-4.
2. **Hardware FIDO2 keys for admins** — any FIDO2-certified key works. Recommended:
   - **YubiKey 5 series (non-FIPS)**: ~$50/key, widely supported.
   - **Token2 PIN+ keys**: ~$25/key, FIDO2 L1 certified, EU-made.
   - **SoloKeys v2** (open-source firmware): ~$30/key, fully open hardware/firmware, FIDO2 L1.
   - **Tillitis TKey**: open hardware, broader use cases.
3. **TOTP** as recovery only.
4. **No SMS, ever.**

### Privileged user policy (still enforce)
Every admin / support-with-impersonation / SRE account requires two registered FIDO2 hardware keys. WebAuthn-only authentication path; no password fallback for these accounts.

### Upgrade trigger
**Trigger**: federal contractor users; CUI handling; CMMC IA-2(11) phishing-resistant MFA mandate.

**Procedure** (estimated 1–2 weeks):
1. Procure YubiKey 5 FIPS series for affected user population.
2. Enroll new keys; provide enrollment day for in-person verification.
3. Revoke non-FIPS keys for those users.
4. Update Keycloak authentication flow to require `fips_validated_authenticator=true` claim on the policy (custom authenticator or Phase Two flow).

Application code: no changes. WebAuthn protocol is identical.

---

## E. Multi-Tenant Architecture — Identical

Realm-per-enterprise-tenant + shared realm with Organizations for SMB, Postgres RLS for app-tier data isolation. All free, all upstream Keycloak.

---

## F. Compliance Posture — Honest Statement

This OSS edition supports **SOC 2 Type 2** and **ISO 27001:2022** readiness fully. Every control mapping in the original report still works because the protocols, audit logs, and access controls are identical.

What this edition **does not** assert:
- ❌ FIPS 140-2 / 140-3 validated cryptographic modules
- ❌ CMMC Level 2 conformance for cryptographic protection of CUI (NIST SP 800-171 03.13.11)
- ❌ FedRAMP Moderate baseline cryptographic requirements

What this edition **does** assert (and you can defend in a SOC 2 / ISO 27001 audit):
- ✅ Modern cryptography (TLS 1.3, ECDSA-P256 signing, ChaCha20-Poly1305 / AES-GCM)
- ✅ HSM-backed key custody (Cloud KMS is HSM-backed, just not CMVP-listed)
- ✅ Phishing-resistant MFA via WebAuthn
- ✅ Comprehensive audit logging
- ✅ Least-privilege access via SpiceDB and Postgres RLS
- ✅ Workload identity via SPIRE
- ✅ Supply-chain integrity via Sigstore signing and SBOM generation

**Document this gap explicitly** in your security posture page. Honesty with customers about what is and isn't validated is part of the SOC 2 control environment.

---

## G. Session Management — Valkey

**Choice: Valkey 8 (BSD-3-Clause, Linux Foundation).** Drop-in Redis replacement, genuinely open source, used by AWS ElastiCache and Google Memorystore.

Same architecture: BFF stores session in Valkey with at-rest encryption (Valkey supports TLS for transport; for at-rest, encrypt at the application level before write).

No upgrade path needed. Valkey is the long-term answer.

---

## H. Workload Identity — SPIRE (no change)

SPIRE is CNCF graduated, Apache 2.0, fully OSS. The original report's recommendation stands without modification.

Configuration:
- Trust domain per environment (`spiffe://prod.example.internal`).
- Upstream CA: keys stored in Cloud KMS with SPIRE's `aws_kms` / `gcp_kms` / `azure_key_vault` upstream authority plugin.
- Kubernetes attestor + workload selectors based on service account, namespace, image hash.

**Upgrade trigger**: when CMMC enters scope, swap the upstream authority's KMS to a CMVP-listed CloudHSM service, or to an on-prem HSM via PKCS#11. Same SPIRE binaries.

---

## I. Service Mesh — Istio + Upstream Envoy

**Choice: Istio Ambient mode** with SPIRE as external CA. Use upstream Envoy in the data plane.

What you give up vs FIPS-Envoy distribution:
- The Envoy binary is not built against a FIPS-validated crypto module.
- You cannot make a FIPS attestation about data-plane cryptography.

What you keep:
- mTLS everywhere (TLS 1.3, modern ciphers).
- AuthorizationPolicy with SPIFFE IDs as principals.
- Telemetry, tracing, observability.

**Upgrade trigger**: CMMC scope or any contract demanding FIPS-validated data-plane cryptography.

**Procedure**: swap to Tetrate Service Bridge, Solo.io Gloo Mesh, or AWS App Mesh distribution of Envoy. Configuration is identical (Istio APIs are the same). Estimated 2–3 days for the swap, longer for procurement.

---

## J. Privileged Access — Teleport Community

**Choice: Teleport Community (AGPL 3.0).** Internal-use is fine under AGPL — you are not "conveying" Teleport to your customers.

What Community gives you:
- SSH, Kubernetes, database, and web app access proxying.
- Ephemeral certificates (no static SSH keys).
- OIDC/SAML federation to Keycloak.
- Session recording (TTY playback).
- Hardware key requirement for users.
- RBAC.
- Audit log.

What Enterprise adds (defer until needed):
- FIPS 140-2 validated build.
- Per-session MFA, dual-authorization workflows.
- Access requests with approval chains.
- Device trust integration.
- Cloud-hosted control plane option.
- FedRAMP Moderate ATO usage.

**Upgrade trigger**: CMMC scope; SOC 2 customer demanding "session recording with MFA" SLA; FedRAMP requirement.

**Procedure**: license file change, swap to FIPS binaries. Cluster config is unchanged.

### Teleport hardening (Community)
- Auth server in private subnet, HA pair.
- Proxy in public subnet, behind WAF.
- Postgres or DynamoDB backend (encrypted at rest).
- Session recordings to S3 / GCS / Azure Blob with **Object Lock / immutability enabled** — this is critical.
- Authentication via Keycloak OIDC; no local Teleport users in production.
- Hardware key requirement for `roles: ["admin"]` (set `require_session_mfa: hardware_key_touch`).

---

## K. Secrets Management — OpenBao

**Choice: OpenBao (Linux Foundation, MPL 2.0, CNCF Sandbox).** Forked from Vault before HashiCorp's BSL relicense; API-compatible; actively developed; the explicitly OSS path forward.

### Why OpenBao over Vault Community (BSL 1.1)
- BSL is not OSI-OSS. Internal use is allowed but the license can change again.
- OpenBao is committed to MPL 2.0 in perpetuity by the Linux Foundation.
- API compatibility means application code targeting `vault.NewClient()` works against either; only the URL changes.
- Migration path to Vault Enterprise (when CMMC arrives) is clean — same KV paths, same auth methods, same policy syntax.

### What OpenBao does today
- KV v2 secret store.
- Database secrets engine (dynamic Postgres, MySQL credentials).
- PKI secrets engine (issue short-lived certs).
- Transit secrets engine (encryption-as-a-service).
- AppRole, Kubernetes auth methods.
- Audit logging.
- Shamir or auto-unseal via Cloud KMS.

### Configuration
- Storage backend: Postgres (HA-capable, simpler than Raft for small deployments) or integrated Raft.
- Auto-unseal: Cloud KMS (AWS KMS, GCP KMS, Azure Key Vault) — same as Vault.
- Auth methods: Kubernetes (for workloads), OIDC to Keycloak (for humans).
- Audit: file + syslog → Wazuh.

### Upgrade trigger
**Trigger**: CMMC scope; FIPS auto-unseal required; Vault Enterprise namespaces needed for multi-tenant secrets isolation; performance replication for multi-region.

**Procedure** (estimated 1–2 weeks):
1. Stand up Vault Enterprise FIPS cluster alongside OpenBao.
2. Use the migration tool (or a script reading from one and writing to the other — KV paths are compatible).
3. Switch application secret references to point at Vault.
4. Decommission OpenBao.

Application code does not change because the API surface is the same.

---

## L. Key Custody — Cloud KMS Standard Tier

**Choice: Cloud KMS (AWS KMS / Azure Key Vault / GCP Cloud KMS) standard tier.** All three are HSM-backed by hardware that is FIPS 140-2 Level 3 certified at the *infrastructure* level, but the standard tier does not give you a CMVP certificate number you can cite.

### What this gets you
- Hardware-backed key generation, storage, and operations.
- Key rotation, IAM-integrated access control, CloudTrail-style audit logs.
- PKCS#11 access for Keycloak signing keys, SPIRE upstream CA, OpenBao auto-unseal.
- Cost: ~$1/key/month + ~$0.03 per 10k operations. For our scale, **expect $50–$200/month total.**

### What you give up vs CloudHSM / on-prem HSM
- No CMVP certificate naming you as the operator of a validated module (the cloud provider is).
- Cannot assert FIPS 140-2 compliance for your application's cryptographic boundary.
- No physical key custody.

### Hardening today
- Per-environment KMS keys (dev/stage/prod separated).
- IAM policies restricting key usage to specific roles/service accounts only.
- Multi-region key replication for disaster recovery.
- Key rotation enabled (90-day default).
- Audit logs streaming to SIEM.

### Upgrade trigger
**Trigger**: CMMC; FedRAMP; specific customer requirement for "FIPS 140-2 Level 3 dedicated HSM."

**Procedure** (estimated 2–3 weeks):
1. Provision CloudHSM cluster (AWS) or Managed HSM (Azure) or on-prem Thales/YubiHSM.
2. Generate new keys in HSM.
3. Re-key Keycloak realms, SPIRE upstream CA, Vault root with overlap windows.
4. Decommission KMS-stored keys.

Application code: no changes. PKCS#11 client code is identical between KMS and HSM.

---

## M. SIEM and Observability — Wazuh

**Choice: Wazuh 4.x (AGPL 3.0).** Production-grade open-source SIEM with HIDS, FIM, vulnerability detection, MITRE ATT&CK mapping, and cloud security posture features. Used at scale in regulated industries.

### Architecture
- Wazuh manager cluster (HA pair).
- OpenSearch backend (Apache 2.0) — stores events.
- Wazuh Dashboard for analysts.
- Agents on every node and (optionally) every container.
- Log ingestion from Keycloak event listener, SpiceDB structured logs, BFF access logs, OpenBao audit, Teleport audit, Postgres logs, Kubernetes audit.

### What Wazuh handles well
- File integrity monitoring on critical paths.
- Authentication failure detection across all sources.
- Vulnerability scanning of installed packages.
- MITRE ATT&CK rule coverage.
- Compliance reporting templates (PCI, HIPAA, GDPR, NIST 800-53).
- Active response (block IP, kill process) — use cautiously.

### What it doesn't replace
- Distributed tracing — use OpenTelemetry → Jaeger or Tempo.
- APM — Pyroscope (open source) or Sentry self-hosted.
- Real-time application metrics — Prometheus + Grafana.

### Upgrade trigger
**Trigger**: dedicated SOC team that wants Splunk's UX; contractual SIEM SLA from a customer; analyst-hour budget that exceeds Wazuh's operational cost.

**Procedure**: deploy Splunk / Elastic / Sumo alongside; configure Wazuh agents to dual-ship; cut over when ready. Wazuh remains as the agent fleet either way (it's the data source).

---

## N. Supply Chain — All OSS Already

The supply-chain stack from the original report is already 100% OSS:
- **Sigstore Cosign** — keyless signing of container images, attestations to Rekor transparency log.
- **Syft** — SBOM generation (SPDX or CycloneDX).
- **Trivy** — image and IaC scanning.
- **Grype** — vulnerability scanning.
- **gitleaks / trufflehog** — pre-commit secret scanning.
- **Semgrep CE** — SAST in CI.
- **Renovate** — dependency updates (Apache 2.0, self-hostable).
- **Kyverno** — Kubernetes admission policy (Apache 2.0, CNCF graduated).
- **OWASP ZAP** — DAST.
- **nuclei** — vulnerability templates.

No upgrade required. Some teams later add Snyk for the UX and ecosystem coverage; this is optional.

---

## O. Day-One Deployment Sequence

This is the ordered build plan for the OSS stack. Estimated total time: **8–12 weeks for one engineer**, faster with parallel work.

### Week 1–2: Foundation
1. Kubernetes cluster (managed: EKS/GKE/AKS recommended — operating your own K8s control plane is not where to spend security budget at this stage).
2. Postgres (managed: RDS/Cloud SQL/Azure DB) for Keycloak, SpiceDB, OpenBao, application data.
3. Valkey cluster for BFF sessions.
4. Cloud KMS keys provisioned, IAM policies set.
5. cert-manager + Let's Encrypt for TLS automation.
6. Sigstore Cosign + Kyverno for signed-image admission.

### Week 3: SPIRE
1. SPIRE server with Cloud KMS upstream authority.
2. SPIRE agent DaemonSet on every node.
3. Trust domain per environment.
4. Validate workload attestation with a hello-world workload getting an X.509-SVID.

### Week 4–5: Keycloak
1. Deploy Keycloak Operator.
2. Create initial realm (`platform` for your team) federated to your existing IdP (Google Workspace, etc.).
3. Configure HSM-backed signing keys via Cloud KMS PKCS#11.
4. Enable OIDC, disable legacy flows.
5. Configure event listener → Kafka → Wazuh.
6. Stand up admin console on a separate, restricted hostname.

### Week 6: SpiceDB
1. Deploy SpiceDB with Postgres backend.
2. Define initial schema (platform, app, resource tiers).
3. mTLS-only API surface; PSK rotated weekly via OpenBao.
4. Validate `CheckPermission` from a test client.

### Week 7: OpenBao
1. Deploy OpenBao with auto-unseal via Cloud KMS.
2. Postgres backend for HA.
3. Enable Kubernetes auth method, OIDC auth method (Keycloak).
4. Create initial KV paths and policies.
5. Audit log → file → Wazuh.

### Week 8: Istio Ambient + BFF
1. Deploy Istio Ambient with SPIRE as external CA.
2. AuthorizationPolicy enforcing SPIFFE-ID-based access between services.
3. Build BFF service (Go recommended, ~200 lines): OAuth 2.1 client to Keycloak, Valkey-backed session, cookie out, JWT in.
4. Hook up first SPA (Proposal Forge) to BFF.

### Week 9: Wazuh + Observability
1. Wazuh manager + OpenSearch.
2. Agent DaemonSet.
3. Log ingestion from all components.
4. Initial dashboards and alerting rules.
5. Prometheus + Grafana for metrics; OpenTelemetry → Tempo/Jaeger for traces.

### Week 10: Teleport
1. Teleport cluster (auth + proxy).
2. Postgres backend.
3. OIDC federation to Keycloak.
4. Hardware-key requirement for admin role.
5. Session recording to S3 with Object Lock.
6. Add SSH, Kubernetes, and Postgres targets.

### Week 11–12: Hardening pass and runbook
1. Walk through the original report's hardening checklist.
2. Penetration test (OSS tools: ZAP, nuclei, ffuf against staging — your SecForge MVP).
3. Document operational runbooks: incident response, key rotation, certificate rotation, breach notification, backup restore.
4. Tabletop exercise.

---

## P. Total Cost Profile (OSS Edition)

| Category | Annual cost (USD) |
|---|---|
| **Software licenses** | **$0** |
| Cloud KMS (3 environments × ~$50/mo) | ~$1,800 |
| Hardware FIDO2 keys (50 admins × 2 keys × $50) | $5,000 (one-time, ~$1,000/yr amortized) |
| Domain SSL (Let's Encrypt) | $0 |
| Sigstore | $0 |
| Cloud infrastructure (K8s, Postgres, Valkey, S3) | $30,000–$80,000 (varies by scale) |
| **Total** | **~$33k–$83k/year**, mostly compute/storage |

Compare to the CMMC-ready edition's $200k–$465k/year envelope. The delta is the cost of compliance optionality, which you can buy when you have a contract that pays for it.

---

## Q. Upgrade-Trigger Summary (the most useful page in this doc)

Pin this on the wall. When any of these conditions becomes true, that component upgrades.

| Trigger event | Component(s) to upgrade |
|---|---|
| First customer questionnaire mentioning FIPS 140 | Keycloak → RHBK; KMS → CloudHSM; OpenBao → Vault Enterprise |
| First federal contract opportunity | Everything FIPS-relevant: IdP, Vault, Teleport, Envoy, FIDO2 keys |
| CMMC Level 2 self-assessment scoping | All of the above + formal control mapping refresh |
| First $100k+ ACV enterprise customer | Optional: AuthZed Enterprise, Teleport Enterprise (for SLA) |
| Multi-region deployment requirement | Vault Enterprise (replication), AuthZed Enterprise (multi-region dispatch) |
| Dedicated SOC team hired | Splunk/Elastic alongside Wazuh |
| Healthcare or financial customer (HIPAA, PCI DSS L1) | Vault Enterprise (audit), Teleport Enterprise (session recording SLA) |
| Customer demands "validated cryptography" without specifying FIPS | Often satisfied with CloudHSM tier alone — cheapest upgrade |

---

## R. What to Watch (and Re-evaluate Every 6 Months)

The OSS landscape moves fast. Re-check these specifically:
- **OpenBao FIPS status.** Linux Foundation is targeting FIPS validation; if it lands, the Vault Enterprise upgrade trigger may collapse to "OpenBao with FIPS profile enabled."
- **Keycloak SCIM in-tree.** A maintained in-tree SCIM 2.0 server would remove the SPI dependency.
- **OpenFGA Zookies.** If true consistency tokens ship, OpenFGA + Keycloak's native authz integration may become more attractive than SpiceDB.
- **Post-quantum cryptography rollout.** Keycloak, OpenBao, SPIRE all need PQ algorithm support by 2027–2028. ML-KEM and ML-DSA are NIST finalists.
- **eBPF-based service mesh** (Cilium Service Mesh). Lower overhead than Istio Ambient; SPIRE integration maturing.

This doc is a snapshot. Architecture decisions outlive any single component choice; revisit components, never the principles.
