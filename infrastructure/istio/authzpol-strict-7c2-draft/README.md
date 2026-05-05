# Phase 7c-2 — full SPIRE-as-CA + multi-ns STRICT scaffolding (DRAFT, NOT applied)

> **Status: DRAFT — these targets the FULL Phase 7c-2 cutover (SPIRE-as-CA + multi-ns expansion + cluster.local → secforge.local trust-domain unification).** Phase 7c-1 (2026-05-05) instead landed a smaller, scope-limited STRICT in `app` ns under the existing `cluster.local` trust domain — see PLAN.md § Phase 7c-1 and `infrastructure/istio/05-peer-auth-app-strict.yaml`. None of the YAMLs in this directory are applied as part of 7c-1.
>
> Phase 7c-2 is tracked as **operator-backlog #21**. Pre-requisite: validate the helm-values diff in `helm-values-spire-ca.draft.diff` against the upstream Istio + SPIRE compatibility docs ([istio.io/latest/docs/ops/integrations/spire](https://istio.io/latest/docs/ops/integrations/spire/)) before any apply. The CNPG PERMISSIVE workload-scoped override added in 7c-1 (`infrastructure/istio/05-peer-auth-app-cnpg-permissive.yaml`) is removed as part of 7c-2 closeout, once openbao + postgres-operator + observability namespaces are mesh-enrolled.

---

## Why this scaffolding is parked here

The original Phase 7c plan was a single all-or-nothing cutover. During the 2026-05-05 audit cleanup, the operator chose option A — STRICT in `app` ns only, under `cluster.local`. That smaller cutover landed in 7c-1; this directory holds the larger 7c-2 prep work that did NOT land in that change.

The trust-domain rewrite (`spiffe://cluster.local/...` → `spiffe://secforge.local/...`) and the multi-ns AuthorizationPolicy templates here both target the 7c-2 scope. They will need re-validation when 7c-2 actually runs (cluster state will have drifted).

---

## Cluster baseline (captured 2026-05-05)

### Mesh enrollment

Only **`app`** is namespace-labeled `istio.io/dataplane-mode: ambient`.
Every other namespace (keycloak, spicedb, openbao, observability,
teleport, ingress-nginx, etc.) is OUT of the mesh today. SPIRE-managed
identities exist in those namespaces (the `spiffe.io/spire-managed-identity:
true` label is set on certain pods) but those identities are **not used by
ztunnel** until SPIRE-as-CA is enabled.

Implication for 7c-2: STRICT PeerAuthentication only takes effect on **mesh-resident pods**. Today that is the `app` namespace's workloads. Until other namespaces are labeled `istio.io/dataplane-mode: ambient`, STRICT in those namespaces is a no-op.

### PeerAuthentication (post-7c-1)

```
istio-system/default          PERMISSIVE   (mesh-wide default — unchanged)
app/default                   STRICT       (added 7c-1, scoped to app ns)
app/secforge-app-db-permissive PERMISSIVE  (workload-scoped override on cnpg.io/cluster=secforge-app-db; added 7c-1, removed in 7c-2)
```

### AuthorizationPolicies in mesh-enrolled namespaces (`app`)

```
app/default-deny                          (selector: secforge.platform/mesh-authz=enforce)
app/allow-app-to-authzen-facade           ALLOW
app/allow-prometheus-to-authzen-metrics   ALLOW
```

Policies use `principals: ["cluster.local/ns/app/sa/<sa>"]` today (7c-1 left them unchanged because option A keeps the existing trust domain). 7c-2 rewrites these to `spiffe://secforge.local/ns/app/sa/<sa>` once SPIRE is the mesh CA. (Istio's URI-prefix matching syntax: `cluster.local/...` becomes `secforge.local/...` when the trust domain flips.)

### Mesh pods today (single-source inventory)

```
app/authzen-facade                  sa=authzen-facade
app/legacy-env-warner-<cron>        sa=legacy-env-warner
app/security-events-collector       sa=security-events-collector
app/weekly-template-drift-<cron>    sa=weekly-template-drift
app/secforge-app-db-1               sa=secforge-app-db    (CNPG pod; ambient.istio.io/redirection=enabled)
```

(Phase 10 BFFs and backends will reappear when project-tracker / proposal-forge land. The 7c-2 cutover plan must accommodate those returning AFTER 7c-2 closes — which the existing AuthorizationPolicy templates handle via SPIFFE-ID-bound rules.)

---

## Non-mesh callers that hit mesh-resident pods

These need explicit handling before STRICT is safe across the rest of the platform.

| Source | Source SPIFFE-ID? | Target | Resolution under 7c-2 STRICT |
|---|---|---|---|
| ingress-nginx → `app/<bff>:3000` | No (ingress-nginx is not in the mesh today) | future BFFs in app | Either mesh-enroll ingress-nginx or AuthorizationPolicy ALLOW with `from.source.notNamespaces: []` (no auth required at L7) — the latter loses transport-layer attestation |
| openbao (non-mesh) → `app/secforge-app-db-1:5432` | No | DB | Mesh-enroll the openbao namespace **as part of the same change window**, so openbao traffic is mTLS-authenticated under SPIRE-issued SVID. Alternative: opt secforge-app-db-1 OUT of the mesh — rejected, because that loses mTLS entirely on the most sensitive in-cluster path. **Currently handled in 7c-1 by a workload-scoped PERMISSIVE override; 7c-2 removes that override once openbao is mesh-enrolled.** |
| postgres-operator (non-mesh) → `app/secforge-app-db-1` | No | DB | CNPG operator probes; same path as openbao. Same resolution: mesh-enroll postgres-operator OR keep covered by the 7c-1 PERMISSIVE override. |
| observability (non-mesh) → `app/secforge-app-db-1:9187` | No | postgres-exporter | Same shape; 7c-2 mesh-enrolls observability. |
| openbao → `app/spicedb:50051` | No | spicedb (NOT mesh-enrolled today) | spicedb is only mesh-enrolled if the spicedb ns gets labeled. If we're touching the mesh anyway, mesh-enrolling spicedb gets us mesh-attested AuthZ-engine traffic. |
| kubelet probes (host network) → mesh pods | N/A (host network has no SVID) | Liveness/Readiness probes | AuthorizationPolicy ALLOW with `from.source.principals: []` and `to.operation.notPaths: ["/healthz", "/ready"]` inverted — Istio's recommended pattern is `pilot.env.PILOT_ENABLE_K8S_SELECT_HEALTHCHECK=false` and explicit allow on those paths |
| prometheus → mesh metrics endpoints | No | `app/authzen-facade:9091` (already covered by `allow-prometheus-to-authzen-metrics`) | The existing policy uses an IPv4-block based ALLOW (since prometheus isn't in the mesh either); preserve under SPIRE-CA |
| spire-csi (host volume) into pods | N/A | (no traffic; just CSI mount) | No action |

---

## Two cutover styles considered

### Style A — Mesh-enroll everything in the same window (RECOMMENDED for 7c-2)

Label `keycloak`, `spicedb`, `openbao`, `observability`, and `teleport`
namespaces with `istio.io/dataplane-mode: ambient` as part of the cutover.
This eliminates the non-mesh-caller problem at the source: every legitimate
caller now has a SPIFFE-ID and mTLS handshakes succeed.

**Pros:** uniform mesh posture; AuthorizationPolicies become the single
source of truth; no `notNamespaces` / `notPrincipals` escape hatches.

**Cons:** larger blast radius; more pods need ztunnel redirect to work
correctly; CNPG pod was already mesh-enrolled implicitly (via the `app`
ns label) so no surprise there, but openbao's seal/unseal logic and
SPIRE-CSI mount sequencing need verification under ztunnel redirect.

### Style B — Keep openbao + others non-mesh; use AuthorizationPolicy `notNamespaces` escapes

Stays with PERMISSIVE-equivalent for non-mesh callers via L7 policy.

**Pros:** smaller change.

**Cons:** loses transport-layer attestation for the openbao→DB path; we
have to maintain `notNamespaces` ALLOWs forever; doesn't get us closer
to the production posture.

**Choice:** Style A. 7c-2 is the right time to bite this.

---

## Drafted AuthorizationPolicies (Style A — for 7c-2, NOT applied in 7c-1)

The `<ns>.yaml` files in this directory are draft scaffolding under the
SPIRE trust domain `secforge.local`. They are NOT applied in 7c-1.

| File | Namespace | What it allows |
|---|---|---|
| `app.yaml` | app | default-deny + allow-app-to-authzen-facade + allow-prometheus-to-authzen-metrics + allow-bff-to-secforge-app-db (returning Phase-10 BFFs) + ingress-nginx → BFF |
| `keycloak.yaml` | keycloak | default-deny + ingress-nginx → keycloak:8443 + prometheus → keycloak:8080 (metrics) |
| `spicedb.yaml` | spicedb | default-deny + app/authzen-facade → spicedb:50051 + spicedb-datastore-refresher → openbao + prometheus → spicedb metrics |
| `openbao.yaml` | openbao | default-deny + every helloworld-bff / helloworld-backend / spicedb-datastore-refresher / vso → openbao:8200 + spire-csi → spire workload api (out-of-mesh; doc-only) + ingress-nginx → openbao:8200 (admin UI) |
| `teleport.yaml` | teleport | default-deny + ingress-nginx → teleport-proxy:443 |

`observability.yaml` is intentionally NOT drafted yet — STRICT in
observability comes last and may need its own iteration based on what the
verify-e2e Loki query surfaces.

---

## SPIRE-as-CA helm values — draft diff

See `helm-values-spire-ca.draft.diff` in this directory. Top-level
changes:

```diff
# infrastructure/istio/02-istiod-values.yaml
+ pilot:
+   env:
+     PILOT_ENABLE_AMBIENT: "true"
+     # SPIRE-as-CA: ambient ztunnel + waypoints fetch SVIDs from
+     # SPIRE workload API rather than minting via Citadel.
+     PILOT_ENABLE_NETWORK_POLICY_PEER_AUTHENTICATION: "true"
+
+ meshConfig:
+   trustDomain: secforge.local
+   defaultConfig:
+     proxyMetadata:
+       ISTIO_META_DNS_CAPTURE: "false"

# infrastructure/istio/04-ztunnel-values.yaml
+ # SPIRE Workload API socket — read SVIDs from SPIRE.
+ extraVolumes:
+   - name: spiffe-workload-api
+     csi:
+       driver: csi.spiffe.io
+       readOnly: true
+ extraVolumeMounts:
+   - name: spiffe-workload-api
+     mountPath: /var/run/secrets/workload-spiffe-uds
+     readOnly: true
+ env:
+   ISTIO_META_CA_PROVIDER: "spire"
+   CA_ADDR: "unix:///var/run/secrets/workload-spiffe-uds/socket"
```

These are the standard Istio Ambient + SPIRE wiring (`istio.io/docs/ops/integrations/spire/`).
The diff is a draft; the operator's go-ahead step is to validate against
the upstream Istio + SPIRE compatibility matrix at cutover-time.

---

## What 7c-2 actually does (when it runs)

Once the operator approves and the Phase 7c-2 window opens:

1. Bump ztunnel to TRACE via the admin port (per pod, no helm upgrade)
   per PLAN.md § Phase 7c 2026-05-03 update — denial visibility.
2. Apply the SPIRE-as-CA helm values diff (`helm upgrade istio-base/
   istiod / ztunnel`). Verify mesh stays up via existing smoke tests.
3. Label the candidate namespaces (Style A list) `istio.io/dataplane-mode: ambient`.
   Wait for ztunnel to reconcile redirect on each.
4. Apply the AuthorizationPolicies in this directory.
5. Flip PeerAuthentication PERMISSIVE → STRICT per the runbook's staged
   order (istio-system → keycloak → spicedb → openbao → app →
   observability), waiting 5 minutes between stages and verifying via
   the Loki AuthZ-deny query.
6. **Remove the 7c-1 CNPG PERMISSIVE workload override**
   (`05-peer-auth-app-cnpg-permissive.yaml`) once openbao +
   postgres-operator + observability are mesh-enrolled.
7. After full flip: drop ztunnel back to RUST_LOG=info.
8. ADR-0010 status: "Accepted with deferral" → "Accepted" (since the
   deferral resolved).
9. Tag cluster `phase-7c-complete`.
10. Update PLAN.md Phase 7c-2 row 🟨 → ✅ + quick-ref table in lockstep.
11. Close operator-backlog #21.

Estimated window: 90–120 min once started.

---

## Baseline files for reference

- `baseline-2026-05-05.yaml` — captured `kubectl get authorizationpolicy -A -o yaml` at S2 prep time (2026-05-05). Re-capture at 7c-2 cutover-time so any drift surfaces.
