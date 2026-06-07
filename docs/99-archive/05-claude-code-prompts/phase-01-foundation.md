> 🗄️ **ARCHIVED 2026-06-07 — local-first / build-era document.**
> This describes the original Docker Desktop / WSL2 / `secforge.local` build, **not** the current
> bare-metal `secforge-prod` deployment. Kept for history only. For current state see `PLAN.md`,
> `docs/01-architecture/`, and `docs/06-reference/operator-backlog.md` (archive index: `docs/99-archive/README.md`).

# Phase 1 — Foundation Cluster Services

> **Navigation:** ⬅ [Previous: Phase 0 — Prerequisites](./phase-00-prerequisites.md) · [Next: Phase 2 — SPIRE](./phase-02-spire.md) ➡ · [📋 PLAN.md](../../PLAN.md) · [Phase prompts index](./README.md)
>
> **Depends on (must be ✅):** Phase 0
> **Blocks:** Phases 2–11 (all subsequent infrastructure rests on Phase 1's namespaces, cert-manager, ingress-nginx, Postgres, Valkey, MinIO)
>
> **Status (mirrors PLAN.md, last updated 2026-05-01):** ✅ Complete (2026-04-28).
>
> PLAN.md is the source of truth for phase status. If this block diverges from PLAN.md's quick-ref table, **PLAN.md wins**; update this block in the same edit that bumps PLAN.md.

**Estimated time:** 2-3 days

**Prerequisites:** Phase 0 complete.

---

## Goal of this phase

Deploy the cluster-wide services every component depends on: namespaces with quotas, ingress-nginx, cert-manager wired to your mkcert CA, the Postgres operator, Valkey, MinIO (local S3), and Kyverno admission control.

After this phase, you have a "blank canvas" of cluster primitives. Subsequent phases install the platform components (Keycloak, SpiceDB, etc.) on top.

---

## What you (the human) need to do first

1. Confirm `kubectl get nodes` shows a healthy `docker-desktop` node.
2. Have your `~/.local/secforge-certs/secforge.local.pem` and `secforge.local-key.pem` ready (from `docs/00-getting-started/03-local-dns-and-tls.md`).

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code.

---

```
We're starting Phase 1 of the SecForge Local Edition platform build. Read CLAUDE.md, PLAN.md, docs/01-architecture/00-overview.md, and docs/05-claude-code-prompts/phase-01-foundation.md before doing anything.

Your task is to deploy the foundation cluster services on Docker Desktop K8s. Work in sub-phases. After each, show me what you did, then wait for my green light to continue.

## Phase 1.1 — Namespaces and quotas

Create namespaces with appropriate labels and ResourceQuotas:
- cert-manager
- ingress-nginx
- postgres-operator
- valkey
- minio
- kyverno
- spire (placeholder; populated in Phase 2)
- keycloak (placeholder)
- spicedb (placeholder)
- openbao (placeholder)
- istio-system (placeholder)
- observability (placeholder)
- wazuh (placeholder)
- app (where Hello World will live)

For each namespace:
- Label: `secforge.platform/component=<component>`, `secforge.platform/edition=local`
- ResourceQuota: limit total CPU and memory to reasonable values that prevent any single component from starving the cluster
- LimitRange: default request/limit per pod

Document the namespace inventory in docs/06-reference/namespaces.md.

Show me the YAML before applying.

## Phase 1.2 — ingress-nginx

Install ingress-nginx via Helm. Configure for Docker Desktop K8s:
- Service type LoadBalancer (Docker Desktop binds it to localhost:80 and localhost:443)
- Default SSL certificate using our mkcert wildcard cert (we'll create the secret next step)
- Disable HTTP/2 if any issues arise; otherwise leave it enabled
- Enable the validating webhook
- Use an appropriate resource request (256Mi memory / 200m CPU)

## Phase 1.3 — Wildcard TLS secret + cert-manager

First, create a Kubernetes Secret in `cert-manager` namespace named `mkcert-ca-key-pair` containing the mkcert root CA cert and key. Read these from my mkcert CAROOT directory — ask me to provide the path or read it via `mkcert -CAROOT` command.

Then install cert-manager via Helm.

Then create a ClusterIssuer named `mkcert-issuer` of type `ca` referencing the secret. This means cert-manager will issue certs from our local CA, signed by it, browser-trusted automatically.

Verify by issuing a test Certificate for `test.secforge.local` and confirming it's issued, valid, and trusted by `curl` from inside the cluster.

## Phase 1.4 — Postgres operator and instances

Use CloudNativePG (the recommended Kubernetes-native Postgres operator):
- Install the operator into `postgres-operator` namespace
- Create five Cluster custom resources, each with:
  - 1 instance (HA isn't meaningful on a single-node cluster)
  - Postgres 16
  - 5 GB PVC
  - Encrypted password storage
  - Self-signed TLS for in-cluster connections
  - Distinct credentials per instance, stored as Secrets

Instances:
- secforge-keycloak-db
- secforge-spicedb-db
- secforge-openbao-db
- secforge-teleport-db (skip if you'll skip Teleport in Phase 8)
- secforge-app-db

Document connection details for each in docs/06-reference/postgres-instances.md. Make sure passwords are NOT in plain text in the doc; reference the Secret names instead.

## Phase 1.5 — Valkey

Install Valkey via the Bitnami chart (or the upstream Valkey chart if available):
- 1 master, 0 replicas (sufficient locally)
- Authentication enabled, password stored as a Secret
- TLS optional locally; document the gap if disabled
- Persistent volume for the AOF
- Resource requests: 128Mi memory, 100m CPU

## Phase 1.6 — MinIO (local S3)

Install MinIO via the upstream Helm chart:
- 1 replica (single-node deploy)
- Console exposed at `https://minio.secforge.local`
- Root credentials stored as a Secret in `minio` namespace; expose to other namespaces only when needed via External Secrets or the OpenBao integration later
- Auto-create buckets:
  - `audit-logs` (immutability would be Object Lock in S3; locally, document the gap)
  - `backups`
  - `wazuh-archive`
  - `teleport-recordings` (if Teleport will be used)
- Set lifecycle rules where applicable

## Phase 1.7 — Cosign + Kyverno

Generate a Cosign keypair for signing platform images. Store the private key in a Kubernetes Secret in the `kyverno` namespace; commit only the public key to the repo at `infrastructure/cosign/cosign.pub`.

Note: in production we'd use Cosign keyless via OIDC. The local key is a documented gap.

Install Kyverno via Helm. Configure two policies:
1. `verify-signatures` policy — running in `Audit` mode in dev (logs violations but doesn't block). Switch to `Enforce` once you're confident: ask me before flipping the switch.
2. `pod-security` policy — Enforce mode. Requires non-root, read-only root FS, drops all capabilities, no privilege escalation.

System namespaces (`kube-system`, `cert-manager`, `kyverno`, `ingress-nginx`) are excluded from these policies.

## Phase 1.8 — Verification

Run a comprehensive check:
- `kubectl get pods --all-namespaces` — everything Running
- `kubectl get certificate -A` — test certificate is Ready
- Test that `https://test.secforge.local` (set up an Ingress and tiny test pod) returns the test page with a green padlock in the browser
- Test that Postgres connects: `kubectl exec` into a Postgres pod and run `psql`
- Test that Valkey responds: `kubectl exec` into Valkey, `redis-cli ping`
- Test that MinIO is reachable at `https://minio.secforge.local` and you can log in
- Test that Kyverno blocks an unsigned image: try to deploy a random unsigned image into `app` namespace, verify it's denied (or warned, depending on Audit/Enforce mode)
- `kubectl top pods --all-namespaces` — resource usage looks reasonable

Report results. Update PLAN.md to mark Phase 1 complete after my confirmation.

## Phase 1.9 — Documentation

Update:
- docs/06-reference/namespaces.md (the namespace inventory)
- docs/06-reference/postgres-instances.md
- docs/06-reference/cluster-services.md (ingress, cert-manager, Kyverno, etc.)
- docs/02-decisions/0002-cloudnativepg-vs-others.md (ADR for the Postgres operator choice)
- docs/02-decisions/0003-kyverno-audit-mode.md (ADR for starting in Audit mode locally)

## Constraints

- No `*` in RBAC unless absolutely necessary; document any uses
- No long-lived credentials; use Secrets for what needs to be a Secret, but plan for OpenBao migration in Phase 5
- Resource quotas applied to every namespace
- Pre-pull large images if possible (Postgres, MinIO, Kyverno, ingress-nginx) before applying — show me commands
- All TLS certs come from cert-manager + mkcert; no self-signed snowflake certs
```

---

## Success criteria

- [ ] Namespaces created with quotas and labels
- [ ] ingress-nginx installed and serving on localhost:443
- [ ] cert-manager installed; ClusterIssuer `mkcert-issuer` works
- [ ] Test certificate issued and trusted by browser at `https://test.secforge.local`
- [ ] CloudNativePG operator installed; 5 Postgres instances Ready
- [ ] Valkey installed and responding
- [ ] MinIO installed; buckets created; UI reachable
- [ ] Cosign keypair created; public key committed
- [ ] Kyverno installed with policies
- [ ] All pods Running; resource usage <50% of allocated
- [ ] Documentation updated
- [ ] PLAN.md updated

---

## Troubleshooting

### "Helm install fails — image pull errors"
Docker Hub rate limits anonymous pulls. Either log in (`docker login`) or change the chart values to use a non-Docker-Hub registry mirror.

### "Postgres operator pod is CrashLoopBackOff"
Check logs: `kubectl logs -n postgres-operator deployment/cnpg-controller-manager`. Common cause: webhook cert isn't ready yet — wait 60 seconds and the operator typically self-heals.

### "Browser warns about cert at https://test.secforge.local"
mkcert CA isn't in Windows trust store. Re-do the Windows-side install in `docs/00-getting-started/03-local-dns-and-tls.md` Section 1.

### "Kyverno is blocking system pods"
Check the policy's `match`/`exclude` rules. System namespaces should be excluded.

### "Memory pressure warnings"
Reduce resource requests in the values files (or scale down components you're not using). Postgres and MinIO are the largest fixed costs.

---

## What's next

[Phase 2 — Workload Identity (SPIRE)](./phase-02-spire.md).
