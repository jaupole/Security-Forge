# Istio AuthorizationPolicy patterns

> Companion: [docs/01-architecture/07-service-mesh.md](../01-architecture/07-service-mesh.md), [ADR-0010](../02-decisions/0010-istio-ambient-vs-sidecar.md).
> Source-of-truth manifests: `infrastructure/istio/06-authz-default-deny.yaml`.

This runbook documents how AuthorizationPolicy is structured in `app` (and how to extend it as new workloads land), why the choices were made, and known gotchas.

---

## Mental model

Two enforcement layers protect every flow into an `app`-namespace pod, in this order:

1. **NetworkPolicy** (kindnet on Docker Desktop / your CNI in cloud). Enforces source pod IP → destination pod IP at L3-L4. Independent of Istio. Authoritative regardless of mesh state.
2. **AuthorizationPolicy** (ztunnel). Enforces source identity (SPIFFE principal or namespace) → destination workload + port + L7 attributes. Only sees traffic that ztunnel processes — i.e., traffic into ambient-labeled pods.

**A connection must satisfy both.** AuthorizationPolicies are *additive* over NetworkPolicies; they do not replace them. Removing a NetworkPolicy because "the mesh has it covered" is a regression — NetworkPolicy is the only thing protecting non-mesh paths and is what holds during mesh outages.

---

## Default-deny is opt-in (Phase 6.2 → 6.2b)

The `default-deny` AuthorizationPolicy in `app` matches workloads carrying:

```yaml
labels:
    secforge.platform/mesh-authz: enforce
```

Workloads without this label are not subject to default-deny. They fall back to ztunnel's "no AuthorizationPolicy on this workload → permit" default, with NetworkPolicy still gating L3-L4.

### Why opt-in, not blanket default-deny

`from.namespaces` and `from.principals` matchers in AuthorizationPolicy match only **mesh peer identities** — sources with an SVID. Non-mesh sources (sources whose namespace is not ambient-labeled) cannot satisfy them, regardless of what namespace ztunnel resolves their IP to.

In Phase 6.2, the only ambient-labeled namespace is `app`. Cross-boundary sources we legitimately need to allow include:

| Source (non-mesh) | Destination | Reason |
|---|---|---|
| `openbao` ns (OpenBao DB engine) | `app/secforge-app-db:5432` | Mint dynamic Postgres credentials |
| `postgres-operator` ns (CNPG operator) | `app/secforge-app-db:5432` | Cluster reconciliation, probes |
| `ingress-nginx` ns (Phase 6.8) | `app/helloworld-bff:3000` (forthcoming) | External user traffic to BFF |

Putting these destinations under blanket default-deny would block their non-mesh callers. Opt-in keeps the destinations protected by NetworkPolicy (which knows pod IP + namespace and matches non-mesh sources just fine) while applying default-deny only to workloads where mesh authz is *meaningful* — i.e., where every legitimate caller is or will be in-mesh.

When 6.2b lands and openbao + postgres-operator + ingress-nginx are in the mesh, we revisit and broaden the opt-in.

### Workloads opted in today

| Workload | Label applied | When |
|---|---|---|
| `authzen-facade` | `secforge.platform/mesh-authz: enforce` | Phase 6.3 (this phase, via `kubectl patch deployment ... `) |
| `helloworld-bff` | same | Phase 6.8 (set in deployment manifest) |

### Workloads NOT opted in today

| Workload | Reason |
|---|---|
| `secforge-app-db-*` (CNPG cluster) | Has non-mesh callers (OpenBao, CNPG operator, observability postgres-exporter). NetworkPolicy is the gate. Carries a workload-scoped PERMISSIVE PeerAuthentication override under STRICT (Phase 7c-1) — see § "PeerAuthentication STRICT in `app` (Phase 7c-1)" below. |

---

## Adding a new workload

1. **Decide whether to opt into mesh-authz.** Test: are *all* legitimate callers either in-mesh or will be by the time you ship? If yes, opt in. If no (you have a non-mesh caller path), don't opt in until that caller is in the mesh.

2. **If opted in:** add `secforge.platform/mesh-authz: enforce` to the workload's pod-template labels. Add an `AuthorizationPolicy` of `action: ALLOW` with `selector.matchLabels` targeting the workload, naming the legitimate callers via `from.namespaces` (broad) or `from.principals` (narrow, preferred when caller has a stable SPIFFE ID).

3. **Always:** keep an equivalent NetworkPolicy in place. Same source/destination/port match, expressed in CNI-level terms. NetworkPolicy is your steady-state floor.

### Allow-pattern templates

**Allow from a single in-mesh caller (preferred when caller is mesh-resident):**

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
    name: allow-bff-to-helloworld-backend
    namespace: app
spec:
    selector:
        matchLabels:
            app.kubernetes.io/name: helloworld-backend
    action: ALLOW
    rules:
    - from:
        - source:
                principals:
                - "spiffe://cluster.local/ns/app/sa/helloworld-bff"   # <- becomes spiffe://secforge.platform/... after 6.2b
        to:
        - operation:
                methods: ["GET", "POST"]
                paths: ["/api/*"]
```

**Allow from any in-mesh caller in a namespace:**

```yaml
rules:
- from:
    - source:
            namespaces: ["app"]
    to:
    - operation:
            ports: ["8080"]
```

**Allow from a non-mesh caller — DO NOT use principals/namespaces; use NetworkPolicy + don't opt the destination into default-deny.** AuthorizationPolicy cannot identify non-mesh sources by namespace; trying to express this in AuthorizationPolicy will result in silent denial.

---

## Known gotchas

### 1. "ALLOW policies exist, but none allowed"

ztunnel access log error message. Means the destination workload has at least one ALLOW AuthorizationPolicy attached, but none of those policies' rules matched the connection. Common causes:

- The source is non-mesh, and the policy uses `from.namespaces` or `from.principals` (non-mesh sources have no peer identity → no match).
- The destination port doesn't match `to.operation.ports`.
- The policy has the wrong workload selector (`selector.matchLabels` doesn't match the destination pod's labels).

Diagnose with:

```bash
ZP=$(kubectl get pod -n istio-system -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n istio-system "$ZP" -- curl -s localhost:15000/config_dump \
    | jq '.workloads[] | select(.namespace == "app" and .name | startswith("MY_WORKLOAD"))'
```

The output's `authorizationPolicies` array shows which policies are attached. If empty when you expect one, your selector doesn't match.

### 2. PeerAuthentication STRICT vs PERMISSIVE

`PeerAuthentication` is mesh-wide (`istio-system` root namespace). In Phase 6.2 it is `PERMISSIVE` — non-mesh peers can talk plaintext into ambient pods. AuthorizationPolicy then evaluates source identity (or non-identity) and decides.

In `STRICT`, plaintext from non-mesh peers is denied at L4 by ztunnel **before** AuthorizationPolicy evaluates. STRICT is only safe once every legitimate source for every ambient destination is mesh-resident.

**As of Phase 7c-1 (2026-05-05) the `app` namespace is STRICT** under a namespace-scoped override at `infrastructure/istio/05-peer-auth-app-strict.yaml`. The mesh-wide default at `infrastructure/istio/05-peer-auth.yaml` stays PERMISSIVE for all other namespaces. See § "PeerAuthentication STRICT in `app` (Phase 7c-1)" below for the CNPG-specific workload override that this required and its 7c-2 removal trigger.

### 3. AuthorizationPolicy with empty rules denies

```yaml
spec: {}
# or
spec:
    selector:
        matchLabels:
            X: Y
```

An AuthorizationPolicy with `action: ALLOW` (the default) and an empty `rules:` list matches the workload but allows nothing — a deny-all for that workload. This is the mechanic powering our opt-in default-deny.

### 4. ztunnel only sees L4 in the default Ambient configuration

ztunnel itself enforces L4 AuthorizationPolicy fields (ports, namespaces, principals, ipBlocks). For L7 fields (`paths`, `methods`, `headers`, JWT claims), traffic must flow through a **waypoint proxy** for that destination. Phase 6 doesn't deploy waypoints; the BFF (Phase 6.8) will need one if its policy enforces path-level rules.

If you write a policy with L7 fields and no waypoint exists for the destination, the L7 rules are silently ignored — the policy allows whatever the L4 portion permits.

### 5. `principals` MUST omit the `spiffe://` scheme

ztunnel's RBAC engine compares the policy's `principals` value against the SVID URI **with the scheme stripped**. Writing the scheme in your policy will silently fail to match.

```yaml
# WRONG — silently denies even when the source SVID is exactly this:
principals:
- "spiffe://cluster.local/ns/app/sa/service-a"

# RIGHT
principals:
- "cluster.local/ns/app/sa/service-a"
```

The ztunnel access log records the source identity *with* the scheme (`src.identity: spiffe://cluster.local/...`), which makes the bug confusing — the log and the policy look like exact matches and yet the deny fires. This is what the `connection closed due to policy rejection: allow policies exist, but none allowed` error looks like when you've written the policy with the scheme.

This contradicts most Istio documentation examples (which use the full URI form for sidecar mode). Ambient ztunnel is stricter. Validate your policies by tailing ztunnel access logs and confirming a non-zero `bytes_recv` for the legitimate path before declaring the policy correct.

### 6. NetworkPolicy + AuthorizationPolicy interaction

If NetworkPolicy denies the L3-L4 connection, AuthorizationPolicy never gets evaluated (the packet doesn't reach ztunnel). If NetworkPolicy allows but AuthorizationPolicy denies, ztunnel returns RST. The two layers are independent; neither is sufficient on its own.

When debugging, check NetworkPolicy first (`kubectl get networkpolicy -n <ns>`) — it's the more common cause of timeout-style failures (NetworkPolicy → silent drop → connection times out, vs. AuthorizationPolicy → RST).

---

## Verification

```bash
# 1. Re-run Phase 4 SpiceDB checks (mesh-internal AuthZEN → SpiceDB path)
bash infrastructure/spicedb/check-permissions.sh

# 2. Mint a dynamic Postgres credential (cross-boundary OpenBao → Postgres)
NS=openbao POD=openbao-0
SA_JWT=$(kubectl exec -n $NS $POD -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
ADMIN_TOKEN=$(kubectl exec -n $NS $POD -c openbao -- env BAO_SKIP_VERIFY=1 \
        bao write -format=json auth/kubernetes/login role=admin-break-glass jwt="$SA_JWT" \
        | jq -r '.auth.client_token')
kubectl exec -n $NS $POD -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ADMIN_TOKEN" \
        bao read database/creds/helloworld-app-readonly

# 3. Inspect ztunnel's view of policies attached to a destination workload
ZP=$(kubectl get pod -n istio-system -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n istio-system "$ZP" -- curl -s localhost:15000/config_dump | jq '.workloads[].authorizationPolicies' | sort -u
```

---

## PeerAuthentication STRICT in `app` (Phase 7c-1)

Phase 7c-1 (2026-05-05) flipped the `app` namespace from the mesh-wide PERMISSIVE default to STRICT, scoped to that one namespace. The mesh-wide default stays PERMISSIVE for every other namespace; SPIRE-as-CA + multi-ns expansion + trust-domain unification are deferred to Phase 7c-2 (operator-backlog #21).

### Resources applied

| File | Kind / scope | Purpose |
|---|---|---|
| `infrastructure/istio/05-peer-auth-app-strict.yaml` | `PeerAuthentication` namespace-scoped (`namespace: app`, no selector) | Set `mtls.mode: STRICT` for all pods in `app`. |
| `infrastructure/istio/05-peer-auth-app-cnpg-permissive.yaml` | `PeerAuthentication` workload-scoped (`namespace: app`, `selector.matchLabels.cnpg.io/cluster: secforge-app-db`) | Override the namespace STRICT back to PERMISSIVE for the CNPG Postgres pod only — keeps non-mesh callers reachable. |

The mesh-wide `infrastructure/istio/05-peer-auth.yaml` (PERMISSIVE) is unchanged.

### Why CNPG needs the workload-scoped PERMISSIVE override

Three legitimate cross-boundary callers into the CNPG cluster come from non-mesh namespaces and would be denied at L4 under STRICT:

- **`openbao` ns** — the database secrets engine mints dynamic Postgres credentials against `secforge-app-db` (the helloworld-app + Phase-10 app DB; see ADR-0023 for the SpiceDB-side analogue, which lives in a different ns and is unaffected).
- **`postgres-operator` ns** — the CNPG operator continuously reconciles cluster state and runs liveness/readiness probes against the pod.
- **`observability` ns** — postgres-exporter scrape (when wired).

None of those namespaces are mesh-enrolled today. The PERMISSIVE override on the CNPG workload is the minimum-blast-radius way to keep STRICT for every other `app`-ns pod while preserving these paths.

### Removal trigger

This override is temporary. It is removed as part of **Phase 7c-2 closeout** ([operator-backlog #21](../06-reference/operator-backlog.md)) once `openbao` + `postgres-operator` + `observability` namespaces become ambient-mesh-enrolled (and therefore can satisfy mTLS as mesh peers). At that point the override file should be `git rm`'d and the namespace-scoped STRICT applies uniformly to every `app`-ns pod.

### Defense in depth (still in force)

NetworkPolicy continues to gate every CNPG path at L3-L4 — see § "NetworkPolicy + AuthorizationPolicy interaction" above. The PERMISSIVE override loses transport-layer attestation for those non-mesh callers but does not remove IP/port-level filtering. Re-attestation is what 7c-2 restores.

### Diagnose a STRICT denial

When ztunnel rejects a connection under STRICT (no mTLS handshake from a non-mesh source), the denial surfaces at TRACE level only — it is silent at DEBUG / INFO. To investigate:

```bash
# (a) Bump ztunnel to TRACE without a pod restart (per pod, all ds members):
for p in $(kubectl get pods -n istio-system -l app=ztunnel -o name); do
  kubectl exec -n istio-system "${p#pod/}" -- curl -s -X POST 'localhost:15000/logging?level=trace'
done

# (b) Tail the deny lines in Loki:
#   {namespace="istio-system",pod=~"ztunnel-.*"} | json
#     | scope="ztunnel::state" | message=~"deny policy.*"

# (c) Drop back to info when done:
for p in $(kubectl get pods -n istio-system -l app=ztunnel -o name); do
  kubectl exec -n istio-system "${p#pod/}" -- curl -s -X POST 'localhost:15000/logging?level=info'
done
```

The 2026-05-03 PLAN.md update in § Phase 7c documents this admin-port pattern in more detail. Don't leave ztunnel at TRACE indefinitely — it materially increases log volume into Loki.
