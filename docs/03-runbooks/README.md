# Operational Runbooks

Step-by-step procedures for routine and emergency operations. These are populated incrementally as each phase builds the corresponding component.

Each runbook should have:
1. **Scope** — what scenario it covers
2. **Prerequisites** — what you need before starting (access, tools, etc.)
3. **Procedure** — numbered steps
4. **Validation** — how do you know it worked
5. **Recovery** — what to do if it doesn't work
6. **Last tested** — date

## Runbook index

**Identity & Keycloak**
- [`keycloak-operations.md`](./keycloak-operations.md) — realm management, user recovery, DB-only admin
- [`keycloak-client-provisioning.md`](./keycloak-client-provisioning.md) — adding/wiring realm clients
- [`keycloak-realm-hardening-replay.md`](./keycloak-realm-hardening-replay.md) — re-apply realm hardening (DR)
- [`keycloak-master-flow-replay.md`](./keycloak-master-flow-replay.md) — master-realm browser flow replay
- [`keycloak-smtp-setup.md`](./keycloak-smtp-setup.md) — realm SMTP for email
- [`realm-signing-key-rotation.md`](./realm-signing-key-rotation.md) — 90-day signing-key rotation

**Authorization (SpiceDB)**
- [`spicedb-operations.md`](./spicedb-operations.md) — schema migration, datastore-URI rotation, recovery

**Secrets & OpenBao**
- [`openbao-recovery.md`](./openbao-recovery.md) — recovery-key use, quorum loss, break-glass
- [`openbao-seal-unseal.md`](./openbao-seal-unseal.md) — transit auto-unseal + manual unseal
- [`secrets-library.md`](./secrets-library.md) · [`secrets-guardrails-verification.md`](./secrets-guardrails-verification.md) · [`secrets-guardrails-monitoring.md`](./secrets-guardrails-monitoring.md) — `apps/lib/secrets` + guardrails
- [`migrate-env-to-openbao.md`](./migrate-env-to-openbao.md) — move env secrets into OpenBao
- [`transit-key-rotation.md`](./transit-key-rotation.md) — Transit/SSE key rotation
- [`ci-secrets-check.md`](./ci-secrets-check.md) — CI secret-leak gate

**Workload identity (SPIRE)**
- [`spire-rotation.md`](./spire-rotation.md) — operational rotation/troubleshooting
- [`spire-ca-rotation.md`](./spire-ca-rotation.md) — upstream CA rotation

**Service mesh, ingress & network**
- [`istio-authz.md`](./istio-authz.md) — AuthorizationPolicy patterns
- [`istio-peer-auth-tighten.md`](./istio-peer-auth-tighten.md) — PeerAuthentication STRICT staging
- [`ingress-nginx-to-istio-cutover.md`](./ingress-nginx-to-istio-cutover.md) — the ingress-nginx → Istio gateway cutover (ADR-0032)
- [`system-ns-netpol-apply.md`](./system-ns-netpol-apply.md) — system-namespace NetworkPolicies
- [`tailnet-split-dns.md`](./tailnet-split-dns.md) — Tailnet split-DNS for operator hosts (admin.* on the tailnet)

**BFF & API**
- [`bff-operations.md`](./bff-operations.md) — BFF debugging
- [`bff-key-rotation.md`](./bff-key-rotation.md) — BFF DPoP key rotation
- [`api-auth-library.md`](./api-auth-library.md) — `apps/lib/api-auth` operations

**Databases & RLS**
- [`control-db-restore.md`](./control-db-restore.md) — FORCE-RLS-aware control-db restore + DR ordering
- [`force-rls-cutover.md`](./force-rls-cutover.md) — FORCE-RLS migration procedure

**Storage (MinIO)**
- [`minio-sse-rotation.md`](./minio-sse-rotation.md) — SSE-S3 key rotation
- [`minio-version-upgrade.md`](./minio-version-upgrade.md) — MinIO version upgrades
- [`member-hub-documents-bucket.md`](./member-hub-documents-bucket.md) — Member Hub documents bucket + svcacct
- [`ecosystem-graphics-bucket.md`](./ecosystem-graphics-bucket.md) — provision the ecosystem-graphics MinIO bucket + credentials

**Apps & deploys**
- [`deploy-app-image.md`](./deploy-app-image.md) — manual digest-pinned image bump (control/portal/member-hub)
- [`proposal-forge-deploy.md`](./proposal-forge-deploy.md) — Proposal Forge deploy
- [`new-app-bootstrap.md`](./new-app-bootstrap.md) — onboarding a new app
- [`quickbooks-online-setup.md`](./quickbooks-online-setup.md) — QBO integration setup
- [`gotenberg-build-and-deploy.md`](./gotenberg-build-and-deploy.md) — build/deploy/verify the Gotenberg document-rendering service
- [`github-runner-crashloop.md`](./github-runner-crashloop.md) — self-hosted CI runner SessionConflict crash-loop self-heal + cleanup + Wazuh alert

**Observability & SIEM**
- [`grafana-dashboards.md`](./grafana-dashboards.md) · [`alerts.md`](./alerts.md) — dashboards + alert tuning
- [`wazuh-operations.md`](./wazuh-operations.md) — Wazuh manager/indexer ops
- [`audit-anchors.md`](./audit-anchors.md) — app audit-log anchoring/signing
- [`platform-audit-anchor-activation.md`](./platform-audit-anchor-activation.md) — activate the OpenBao audit-log anchor (X-R1)
- [`platform-loki-audit-anchor.md`](./platform-loki-audit-anchor.md) — Loki log-sink audit anchor (X-R1 #85 Phase 2)

**Security, DR & maintenance**
- [`k3s-encryption-reenable.md`](./k3s-encryption-reenable.md) — secrets-at-rest re-enable
- [`base-image-cve-cadence.md`](./base-image-cve-cadence.md) — base-image CVE cadence
- [`velero-restore-drill-leastpriv.md`](./velero-restore-drill-leastpriv.md) — Velero restore drill
- [`dr-drill-tier1-findings.md`](./dr-drill-tier1-findings.md) — Tier-1 DR drill findings
- [`k3s-datastore-restore.md`](./k3s-datastore-restore.md) — k3s SQLite (kine) datastore backup + same-host restore (#95)

> Operator access is the **Tailscale tailnet** (no Teleport) — see
> [01-architecture/09-privileged-access.md](../01-architecture/09-privileged-access.md) and
> [06-reference/operator-cheatsheet.md](../06-reference/operator-cheatsheet.md).

## Quarterly habit

Once a quarter, walk through every runbook end-to-end (in dev or staging, never directly in prod for the first time). Update the "last tested" date. Fix anything that's drifted from reality.

If a runbook hasn't been tested in 6 months, treat it as broken until proven otherwise.
