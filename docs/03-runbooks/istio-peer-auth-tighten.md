# Istio peer-auth tighten — PERMISSIVE → STRICT cutover (Phase 7c runbook)

> **Owner:** Phase 7c (Istio SPIRE-as-CA cutover + PeerAuthentication STRICT). This runbook is what Phase 7c executes. It is NOT to be run during the Fix-after-07 package; that package only writes this doc and prepares AuthorizationPolicies as scaffolding (§B.2 deferred to here).
>
> Companion: [ADR-0010](../02-decisions/0010-istio-ambient-vs-sidecar.md), [`docs/01-architecture/07-service-mesh.md`](../01-architecture/07-service-mesh.md). Closes F-ADR-5 (the missing runbook) by existing.

The cutover from `mode: PERMISSIVE` to `mode: STRICT` on the cluster's PeerAuthentication is one of the highest-risk changes in the platform. Done wrong, every legitimate inter-pod call without a SPIFFE peer identity gets blocked at the mesh layer, which can cascade into K8s API probe failures, dependency outages, and a half-rolled cluster with no clear recovery path.

This runbook makes the cutover staged and reversible: per-namespace, with Loki-backed verification at each stage, with a documented rollback that returns the namespace to PERMISSIVE without scattered cleanup.

---

## Prerequisites

Verify ALL of the following BEFORE starting any of §3's stages. Any "no" stops the run.

- [ ] Phase 7 mainline ✅ (Loki + Tempo live so AuthZ-deny logs have somewhere to land).
- [ ] Phase 7c-prereq §A.6 — SPIRE acts as the mesh CA: ztunnel/istiod issue + verify SPIFFE-IDs from SPIRE, not Citadel. (This runbook is staged under "tighten the mesh enforcement"; the SPIRE-CA cutover is its sister task and lands at the same time. Verify with `istioctl proxy-config secret <pod>` showing SPIRE-issued chain.)
- [ ] Every workload that needs to receive cross-namespace traffic in any of the target namespaces HAS A SPIFFE-ID ALREADY: `kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.labels."spiffe.io/spire-managed-identity"=="true") | .metadata.namespace + "/" + .metadata.name'` lists every mesh-resident pod.
- [ ] Every legitimate cross-namespace call from a non-mesh source (e.g., kubelet probes, the K8s API server, ingress-nginx-without-mesh) has an explicit `from`-less ALLOW (no `principals:`) covering its port.
- [ ] AuthorizationPolicies for the target ns exist BEFORE this stage runs: `kubectl get authorizationpolicy -n <ns>` shows at least a default-deny + an explicit ALLOW for the legitimate caller(s). Fix-after-07 §B.2 deferred this work to here, so this step does the writing AND the cutover in one motion per namespace — see §3's stage detail.
- [ ] Recent backup of cluster state (Helm releases, the AuthorizationPolicy YAMLs, the PeerAuthentication YAMLs as currently committed). The rollback is `kubectl delete peerauthentication ...` but having the originals on hand is cheap insurance.

---

## 1. Per-namespace dry-run

For each target namespace, render the new PeerAuthentication object and verify Kubernetes will accept it before applying:

```bash
NS=keycloak  # one of: istio-system, keycloak, spicedb, openbao, app, observability
cat <<EOF | kubectl apply --dry-run=server -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: $NS
spec:
  mtls:
    mode: STRICT
EOF
```

Expected output: `peerauthentication.security.istio.io/default created (server dry run)`. If anything else (CRD missing, validation error), STOP — investigate before proceeding to §3.

The dry run catches CRD-version mismatches and admission-webhook rejections. It does NOT catch runtime-deny problems; those surface in §3 only after real traffic flows.

---

## 2. Staged rollout order (DO NOT DEVIATE)

Order matters. A target namespace whose downstream isn't yet STRICT-ready can leave the cluster in a half-state that's hard to debug.

```
1. istio-system        — control-plane, no real traffic yet; canary stage
2. keycloak            — first platform ns; failure here is contained (auth login fails)
3. spicedb             — depends on (2); failure means AuthZ checks fail
4. openbao             — depends on (2)+(3); failure means secret bootstraps fail
5. app                 — depends on (2)+(3)+(4); failure means BFF + AuthZEN-facade fail
6. observability       — last; failure here means metrics/logs/traces stop flowing,
                         which is bad but does not cascade into application failure
```

Don't combine. Don't try to pre-stage all six PeerAuthentications and apply at the end — sequential is the whole point.

Wait at least 5 minutes between stages: a workload's first call after a Pod restart can take that long, so 5 min gives newly-rolled callers time to surface mTLS failures in the next stage.

---

## 3. Per-stage execution

For each namespace in the order above, do this dance:

### 3.1 Apply the AuthorizationPolicies for the namespace

If the namespace doesn't yet have a default-deny AuthorizationPolicy plus its specific ALLOWs, write them now (as `infrastructure/istio/authz/<ns>/*.yaml`) and `kubectl apply`. Per the per-namespace ALLOW specifications in [Fix-after-07 § B.2](../../Fix%20after%2007/01-fix-prompt.md):

| ns | What to allow |
|---|---|
| istio-system | (no traffic in/out today; default-deny is fine, no ALLOWs required for the canary stage) |
| keycloak | ingress-nginx → keycloak:8443 |
| spicedb | `app/authzen-facade` SPIFFE-ID → spicedb:50051 |
| openbao | `app/helloworld-bff` SPIFFE-ID → openbao:8200 (and any other SPIFFE-bound caller — read `infrastructure/openbao/policies/` to inventory) |
| app | (already has policies from Phase 6.3) — confirm `default-deny` covers the ns |
| observability | Promtail (DaemonSet) → Loki:3100; Grafana → Loki/Prometheus/Tempo; Alertmanager → Prometheus |

Apply ALL of these with `kubectl apply -f infrastructure/istio/authz/<ns>/`. Wait 30 s for Istio to propagate.

### 3.2 Smoke-test BEFORE flipping STRICT

Per the staged order, every dependency this namespace has should already be STRICT (or nothing — istio-system is first). The smoke tests:

```bash
# ingress-nginx → keycloak (stage 2)
curl -sk -o /dev/null -w "keycloak: %{http_code}\n" https://auth.secforge.dev/realms/secforge-tenants/.well-known/openid-configuration

# app/authzen-facade → spicedb (stage 3)
kubectl port-forward -n app svc/authzen-facade 18080:8080 &
sleep 2
curl -sk http://localhost:18080/readyz; echo

# app/helloworld-bff → openbao (stage 4)
kubectl rollout status deploy/helloworld-bff -n app
kubectl logs -n app deploy/helloworld-bff -c bff --tail=10 | grep -E "starting|oidc client ready|listening"

# (etc — adapt per ns)
```

If any smoke test fails, STOP. Roll back the AuthZ policies if needed. Do NOT proceed to 3.3.

### 3.3 Apply STRICT PeerAuthentication

```bash
NS=<this-stage-ns>
cat <<EOF | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: $NS
spec:
  mtls:
    mode: STRICT
EOF
```

### 3.4 Verification (Loki query)

Wait 5 minutes for any background callers to fire:

```bash
START=$(( $(date +%s) - 600 ))000000000
END=$(date +%s)000000000
PASS=$(kubectl get secret -n observability kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
curl -sk -u "admin:$PASS" -G "https://grafana.secforge.dev/api/datasources/proxy/uid/loki/loki/api/v1/query_range" \
  --data-urlencode "query={namespace=\"istio-system\"} |~ \"PERMISSION_DENIED|RBAC: access denied\"" \
  --data-urlencode "start=$START" --data-urlencode "end=$END" --data-urlencode "limit=20" \
  | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
res=d.get('data',{}).get('result',[])
deny_count=sum(len(r.get('values',[])) for r in res)
print(f'AuthZ-deny lines in last 10 min: {deny_count}')"
```

Zero or near-zero deny count → stage passes; proceed to next namespace after a 5-minute soak. **Any non-trivial deny count → ROLL BACK this stage** (see §4) and add the missing ALLOW before re-attempting.

### 3.5 Soak between stages

Wait 5+ minutes between stages. This catches periodic callers (CronJobs, webhooks fired on K8s events, watcher reconnects) that don't fire on every request.

---

## 4. Rollback (per-stage)

If §3.4's verification surfaces deny traffic from a legitimate caller you didn't anticipate:

```bash
NS=<the-stage-ns>
kubectl delete peerauthentication -n $NS default
```

This returns the namespace to the cluster default (PERMISSIVE — set in `istio-system`). Traffic flows again. Add the missing ALLOW to `infrastructure/istio/authz/<ns>/`, smoke-test again, then re-attempt 3.3.

**Do NOT delete the AuthorizationPolicies**. They aren't the cause of the issue; they're scaffolding for the eventual STRICT cutover.

If the rollback itself doesn't fix things (rare but possible if e.g. ztunnel is itself in a bad state), the heavier escape:

```bash
# Set the cluster default explicitly back to PERMISSIVE
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: PERMISSIVE
EOF
```

This is what was there before; explicit re-statement may shake out a stuck reconciliation.

---

## 5. Final verification (after all stages complete)

```bash
echo "=== every namespace's PeerAuthentication ==="
kubectl get peerauthentication -A
# Expect: every target ns shows mode: STRICT.

echo "=== run verify-e2e.sh ==="
bash infrastructure/observability/verify-e2e.sh
# Expect: still 8/10 or 10/10 (not regressed by the cutover).

echo "=== synthetic AuthZ-deny smoke test ==="
# Spin up a probe pod in `app` ns WITHOUT spire-managed-identity label;
# confirm it CANNOT reach openbao:8200. Expected: connection refused or
# RBAC: access denied in the ztunnel log.
```

If all three pass, the cutover is complete. Update PLAN.md Phase 7c to ✅ and add a one-line summary of the run.

---

## 6. What this runbook does NOT cover

- **The SPIRE-as-CA cutover itself** (mesh certs issued by SPIRE rather than Citadel). That's Phase 7c's first half; this runbook is its second. The two run together.
- **PeerAuthentication policies on individual workloads** (vs. the namespace-level default we apply here). Workload-level policies are a finer-grained tool used only when a single workload needs different mTLS behavior than its namespace; Phase 7c does not need them.
- **Cross-cluster mTLS** (multi-cluster mesh). Out of scope for the local edition.

---

## 7. Audit-finding closure

This runbook closes [F-ADR-5](../../Fix%20after%2007/00-audit-findings.md#f-adr-5--medium--istio-permissivestrict-cutover-has-no-runbook). Phase 7c executes against this runbook; if the runbook needs updating during execution, edit-this-doc-and-re-run is fine — but every change has to come back to the docs immediately, not as a TODO.
