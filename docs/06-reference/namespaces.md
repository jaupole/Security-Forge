# Namespace Inventory (Local Edition)

Authoritative list of Kubernetes namespaces in the SecForge Local Edition cluster, their purpose, owner component, and resource caps.

Source of truth: [`infrastructure/namespaces/namespaces.yaml`](../../infrastructure/namespaces/namespaces.yaml). Apply with `kubectl apply -f infrastructure/namespaces/namespaces.yaml`.

---

## Conventions

Every namespace carries:

- `secforge.platform/component=<component>` — identifies the owning platform component.
- `secforge.platform/edition=local` — distinguishes local-edition resources from any future shared tooling.
- `pod-security.kubernetes.io/enforce=<level>` — Pod Security Admission level (see per-namespace notes; most are `restricted`, infra namespaces that need host access are `privileged`).
- A `ResourceQuota` named `default-quota` capping requests/limits and pod count.
- A `LimitRange` named `default-limits` providing per-container defaults so a pod with no resource block can't bypass the quota.

System namespaces (`kube-system`, `kube-public`, `kube-node-lease`, `default`) are managed by Docker Desktop and are not modified by us.

---

## Namespaces

| Namespace | Component | PSA level | Req CPU | Req Mem | Lim CPU | Lim Mem | Pods | Notes |
|---|---|---|---|---|---|---|---|---|
| `cert-manager` | cert-manager | baseline | 500m | 512Mi | 1 | 1Gi | 10 | TLS issuance via mkcert ClusterIssuer (Phase 1.3). |
| `ingress-nginx` | ingress-nginx | privileged | 500m | 512Mi | 1 | 1Gi | 5 | Privileged because controller binds host ports 80/443. |
| `postgres-operator` | CloudNativePG | restricted | 500m | 512Mi | 1 | 1Gi | 10 | Operator only; database `Cluster` CRs live in consumer namespaces. |
| `valkey` | Valkey | restricted | 500m | 512Mi | 1 | 1Gi | 5 | Single-master locally; sessions store for the BFF. |
| `minio` | MinIO | restricted | 500m | 512Mi | 1 | 1Gi | 5 | Local S3 — audit logs, backups, Wazuh archive, Teleport recordings. |
| `kyverno` | Kyverno | baseline | 1 | 1Gi | 2 | 2Gi | 15 | Admission control; signature verification starts in Audit mode. |
| `spire` | SPIRE | privileged | 500m | 512Mi | 1 | 1Gi | 10 | Placeholder for Phase 2; agent DaemonSet needs hostPath to the kubelet socket. |
| `keycloak` | Keycloak | restricted | 1 | 1500Mi | 2 | 3Gi | 10 | Placeholder for Phase 3. JVM heap dominates memory budget. |
| `spicedb` | SpiceDB + AuthZEN façade | restricted | 1 | 1Gi | 2 | 2Gi | 10 | Placeholder for Phase 4. |
| `openbao` | OpenBao | restricted | 1 | 1Gi | 2 | 2Gi | 10 | Placeholder for Phase 5. Two instances (root + transit-unsealer) fit here. |
| `istio-system` | Istio Ambient | privileged | 1 | 1Gi | 2 | 2Gi | 15 | Placeholder for Phase 6. ztunnel CNI needs privileged. |
| `observability` | Prom / Grafana / Loki / Tempo / OTel | baseline | 2 | 4Gi | 4 | 6Gi | 30 | Placeholder for Phase 7. Largest namespace by RAM. |
| `wazuh` | Wazuh manager + indexer + dashboard | baseline | 2 | 3Gi | 4 | 5Gi | 15 | Placeholder for Phase 7. Indexer dominates memory. |
| `app` | Hello World + Proposal Forge / Project Tracker / PM app | restricted | 1 | 1Gi | 2 | 2Gi | 20 | Phase 9 onwards. |

**Total ResourceQuota requests:** ~12.5 CPU / ~16.4 GiB. Quotas are upper bounds, not reservations — actual steady-state usage is ~7 GiB per `docs/01-architecture/00-overview.md`. With 12 GiB allocated to Docker Desktop the cluster has headroom; 16 GiB is comfortable once the apps are added.

---

## Why Pod Security levels vary

We default to `restricted` (the strictest tier) and only loosen where a component genuinely cannot run under it:

- **`privileged`** — `ingress-nginx` (host port binding), `spire` (hostPath to kubelet), `istio-system` (ztunnel CNI). These three are infrastructure that has to interact with the node directly.
- **`baseline`** — `cert-manager`, `kyverno`, `observability`, `wazuh`. These run several charts whose default values use `runAsNonRoot: true` but not always `readOnlyRootFilesystem`. Rather than fork values, we accept `baseline` here and rely on Kyverno to surface specific violations.
- **`restricted`** — everything else. Application code, databases, Keycloak, SpiceDB, OpenBao, Valkey, MinIO, the `app` namespace.

The `pod-security.kubernetes.io/warn=restricted` label on `baseline` and `privileged` namespaces means we still get warnings on `kubectl apply` for any pod that *could* run restricted but doesn't — making it easy to spot opportunities to tighten.

---

## Why `postgres-operator` doesn't host the databases

CloudNativePG runs the operator in `postgres-operator`, but each `Cluster` custom resource is created in the **consuming namespace**. So:

- `secforge-keycloak-db` lives in `keycloak`
- `secforge-spicedb-db` lives in `spicedb`
- `secforge-openbao-db` lives in `openbao`
- `secforge-teleport-db` lives in (a future) `teleport`
- `secforge-app-db` lives in `app`

This way each database's quota counts against the consuming component's namespace budget, and NetworkPolicies stay simple ("allow same-namespace traffic to the DB"). The `postgres-operator` quota only needs to fit the controller pod itself.

This also means each namespace's quota above already reserves headroom for its database pod (Postgres ~256 MiB request).

---

## Adding a new namespace

1. Add a new section to `infrastructure/namespaces/namespaces.yaml` following the existing pattern (Namespace + ResourceQuota + LimitRange).
2. Add a row to the table above.
3. `kubectl apply -f infrastructure/namespaces/namespaces.yaml`.
4. If the new namespace owns persistent state, also update `docs/03-runbooks/` with backup/restore procedures.
