# Phase 7c — STRICT cutover scaffolding (DRAFT, not applied)

> **Status: DRAFT prepared 2026-05-05.** YAMLs in this directory and the
> Istio-helm values diff in `helm-values-spire-ca.draft.diff` are NOT yet
> applied. Phase 7c executes against the runbook at
> [`docs/03-runbooks/istio-peer-auth-tighten.md`](../../../docs/03-runbooks/istio-peer-auth-tighten.md);
> this scaffolding is what that runbook applies.
>
> Operator must give explicit go-ahead before any kubectl-apply against
> these.

---

## Why a separate directory

The existing `infrastructure/istio/06-authz-default-deny.yaml` carries the
`app`-ns AuthorizationPolicies that landed in Phase 6.3 with the
`spiffe://cluster.local/...` trust domain. The Phase 7c cutover flips the
mesh trust domain to `spiffe://secforge.local/...` (SPIRE-as-CA), which
means EVERY AuthorizationPolicy that names a SPIFFE-ID has to be rewritten
in the same change window. The scaffolding here is the rewritten set,
parked separately so the cutover applies them as a unit AND so the
PERMISSIVE-era policies remain intact during prep.

Once Phase 7c closes, the operator's task is to retire the old
`06-authz-default-deny.yaml` references in favor of these.

---

## Cluster baseline (captured 2026-05-05)

### Mesh enrollment

Only **`app`** is namespace-labeled `istio.io/dataplane-mode: ambient`.
Every other namespace (keycloak, spicedb, openbao, observability,
teleport, ingress-nginx, etc.) is OUT of the mesh today. SPIRE-managed
identities exist in those namespaces (the `spiffe.io/spire-managed-identity:
true` label is set on certain pods) but those identities are **not used by
ztunnel** until SPIRE-as-CA is enabled.

Implication: STRICT PeerAuthentication only takes effect on **mesh-resident
pods**. Today that is the `app` namespace's workloads (authzen-facade,
security-events-collector, legacy-env-warner cronjob, weekly-template-drift
cronjob, secforge-app-db-1 — the CNPG postgres pod is annotated
`ambient.istio.io/redirection: enabled`). Until other namespaces are
labeled `istio.io/dataplane-mode: ambient`, STRICT in those namespaces is
a no-op.

### PeerAuthentication

```
istio-system/default   PERMISSIVE   (mesh-wide default)
```

No per-namespace pin. PERMISSIVE accepts both mTLS (mesh peer) and plain
(non-mesh peer) inbound.

### AuthorizationPolicies in mesh-enrolled namespaces (`app`)

```
app/default-deny                          (action: not set; defaults to ALLOW with empty rules → effective deny)
app/allow-app-to-authzen-facade           ALLOW
app/allow-prometheus-to-authzen-metrics   ALLOW
```

Policies use `principals: ["cluster.local/ns/app/sa/<sa>"]` today. Phase
7c rewrites these to `spiffe://secforge.local/ns/app/sa/<sa>` once SPIRE
is the mesh CA. (Istio's URI-prefix matching syntax: `cluster.local/...`
becomes `secforge.local/...` when the trust domain flips.)

### Mesh pods today (single-source inventory)

```
app/authzen-facade                  sa=authzen-facade
app/legacy-env-warner-<cron>        sa=legacy-env-warner
app/security-events-collector       sa=security-events-collector
app/weekly-template-drift-<cron>    sa=weekly-template-drift
app/secforge-app-db-1               sa=secforge-app-db    (CNPG pod, ambient.istio.io/redirection=enabled)
```

(helloworld-bff / helloworld-backend / helloworld-frontend will reappear
when project-tracker / proposal-forge land in Phase 10. The cutover plan
must accommodate those returning AFTER Phase 7c closes — which the
existing AuthorizationPolicy templates handle via SPIFFE-ID-bound rules.)

---

## Non-mesh callers that hit mesh-resident pods

These need explicit handling before STRICT is safe.

| Source | Source SPIFFE-ID? | Target | Resolution under STRICT |
|---|---|---|---|
| ingress-nginx → `app/<bff>:3000` | No (ingress-nginx is not in the mesh today) | future BFFs in app | Either mesh-enroll ingress-nginx or AuthorizationPolicy ALLOW with `from.source.notNamespaces: []` (no auth required at L7) — the latter loses transport-layer attestation |
| openbao (non-mesh) → `app/secforge-app-db-1:5432` | No | DB | Mesh-enroll the openbao namespace **as part of the same Phase 7c change window**, so openbao traffic is mTLS-authenticated under SPIRE-issued SVID. Alternative: opt secforge-app-db-1 OUT of the mesh — rejected, because that loses mTLS entirely on the most sensitive in-cluster path. |
| openbao → `app/spicedb:50051` | No | spicedb (NOT mesh-enrolled today) | spicedb is only mesh-enrolled if the spicedb ns gets labeled. If we're touching the mesh anyway, mesh-enrolling spicedb gets us mesh-attested AuthZ-engine traffic. |
| kubelet probes (host network) → mesh pods | N/A (host network has no SVID) | Liveness/Readiness probes | AuthorizationPolicy ALLOW with `from.source.principals: []` and `to.operation.notPaths: ["/healthz", "/ready"]` inverted — Istio's recommended pattern is `pilot.env.PILOT_ENABLE_K8S_SELECT_HEALTHCHECK=false` and explicit allow on those paths |
| prometheus → mesh metrics endpoints | No | `app/authzen-facade:9091` (already covered by `allow-prometheus-to-authzen-metrics`) | The existing policy uses an IPv4-block based ALLOW (since prometheus isn't in the mesh either); preserve under SPIRE-CA |
| spire-csi (host volume) into pods | N/A | (no traffic; just CSI mount) | No action |

---

## Two cutover styles considered

### Style A — Mesh-enroll everything in the same window (RECOMMENDED)

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

**Choice:** Style A. Phase 7c is the right time to bite this.

---

## Drafted AuthorizationPolicies (Style A)

The `<ns>.yaml` files in this directory are draft scaffolding under the
SPIRE trust domain `secforge.local`. They are NOT applied. Each file is
self-contained; apply with `kubectl apply -f infrastructure/istio/authzpol-strict/<ns>.yaml`
in the runbook's per-stage step 3.1.

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

## Operator go-ahead — what the cutover actually does

Once the operator approves and the Phase 7c window opens:

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
6. After full flip: drop ztunnel back to RUST_LOG=info.
7. ADR-0010 status: "Accepted with deferral" → "Accepted" (since the
   deferral resolved).
8. Tag cluster `phase-7c-complete`.
9. Update PLAN.md Phase 7c row 🟨 → ✅ + quick-ref table in lockstep.

Estimated window: 90–120 min once started.

---

## Baseline files for reference

- `/tmp/authzpol-baseline.yaml` — captured `kubectl get authorizationpolicy -A -o yaml` at S2 prep time (2026-05-05). Re-capture at cutover-time so any drift surfaces.
