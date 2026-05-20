# Alerts runbook

> Alerts are defined in `platform/manifests/observability/09-platform-alerts.yaml` (node/container health) and `10-app-alerts.yaml` (app/security signals), evaluated by `kps-prometheus`. Until Alertmanager has a real receiver wired, alerts are visible only in:
>
> - Grafana → Alerting → Alert rules
> - Prometheus UI: `kubectl port-forward -n observability svc/kps-prometheus 9090:9090` → http://localhost:9090/alerts
> - Alertmanager UI: `kubectl port-forward -n observability svc/kps-alertmanager 9093:9093` → http://localhost:9093/

When an alert fires, find the matching section below, follow diagnostics, then remediate.

---

## PodCrashLooping

**Trigger:** ≥5 restarts in 15m for any pod in app/keycloak/spicedb/openbao/istio-system/spire/observability/valkey.

**Diagnose:**
```bash
kubectl get pods -A | grep -v "Running\|Completed"
POD=...; NS=...
kubectl describe pod -n "$NS" "$POD" | tail -30
kubectl logs -n "$NS" "$POD" -p --tail=80   # previous container
kubectl logs -n "$NS" "$POD" --tail=80
```

**Common causes:**
- OpenBao sealed → see [OpenBaoSealed](#openbaosealed)
- Postgres unavailable → check `kubectl get cluster.postgresql.cnpg.io -A`
- Image tag drift after rebuild → see PLAN.md note about Docker Desktop containerd-vs-daemon image stores; reimport via `docker save | docker exec -i desktop-control-plane ctr -n=k8s.io image import -`
- SPIFFE-CSI driver not yet registered (post-Docker-Desktop-restart) → see [openbao-seal-unseal.md](./openbao-seal-unseal.md) and the startupProbe gate documented in PLAN.md Phase 7.0.a

---

## OpenBaoSealed

**Trigger:** `vault_core_unsealed{namespace="openbao"} == 0` for 2m.

**Diagnose + remediate:** see [openbao-seal-unseal.md](./openbao-seal-unseal.md). After Docker Desktop restart this is routine: unseal the seal-bao with 3 of 5 Shamir keys, main bao auto-unseals via Transit. If you see `403 permission denied` instead of `503 sealed=true` after seal-bao unseals, the Transit token expired — see [openbao-recovery.md § Rotate the Transit unseal token](./openbao-recovery.md#rotate-the-transit-unseal-token).

---

## NamespaceMemoryHigh

**Trigger:** working-set memory >85% of namespace memory quota for 10m.

**Diagnose:**
```bash
NS=...
kubectl top pods -n "$NS" --sort-by=memory   # requires metrics-server
kubectl describe resourcequota -n "$NS"
```

**Remediate:** identify the heaviest pod, check for memory leaks (heap dumps if Java, pprof if Go). Local-edition note: cold restarts after long pauses can transiently spike. Wait one cycle before acting; if persistent, raise the quota or shed components you're not actively using.

---

## KeycloakHTTP5xxRate

**Trigger:** SERVER_ERROR outcome >5% of all Keycloak HTTP requests for 10m.

**Diagnose:**
```bash
# Keycloak request log
kubectl logs -n keycloak keycloak-0 --tail=200 | jq -c 'select(.level=="ERROR" or .level=="WARNING")'

# Postgres health (Keycloak's #1 dependency)
kubectl get cluster.postgresql.cnpg.io -n keycloak
kubectl logs -n keycloak secforge-keycloak-db-1 --tail=50

# JVM heap pressure
# Check the `JVM heap used %` panel on the Auth events Grafana dashboard
```

**Common causes:** DB pool exhausted ([KeycloakDBPoolExhausted](#keycloakdbpoolexhausted)), realm import broken, JWKS rotation lag, OOM throttling.

---

## KeycloakDBPoolExhausted

**Trigger:** `agroal_available_count{namespace="keycloak"} == 0` for 5m.

**Diagnose:**
```bash
# Look at active vs available
kubectl exec -n keycloak keycloak-0 -- curl -s http://localhost:9000/metrics | grep agroal_

# Postgres connection count
kubectl exec -n keycloak secforge-keycloak-db-1 -- psql -U postgres -c "select count(*) from pg_stat_activity where datname='keycloak';"
```

**Remediate:** check Postgres health (slow queries blocking connections). Raise `db-pool-max-size` Keycloak option as a last resort — usually the upstream is the issue.

---

## SpiceDBCheckLatencyHigh

**Trigger:** p99 CheckPermission latency >500ms for 10m.

**Diagnose:**
```bash
# Cache hit rate (low hit rate = cold cache or eviction pressure)
kubectl port-forward -n spicedb svc/spicedb 9090:9090 &
curl -s http://localhost:9090/metrics | grep -E "spicedb_cache_(hits|misses)_total"

# Postgres latency
kubectl exec -n spicedb secforge-spicedb-db-1 -- psql -U postgres -c "select query, calls, mean_exec_time from pg_stat_statements order by mean_exec_time desc limit 5;"
```

**Common causes:** schema with deep recursion, dispatch cluster mismatched, Postgres slow, cache too small.

---

## SpiceDBGRPCErrorRate

**Trigger:** non-OK gRPC code rate >5% for 10m.

**Diagnose:**
```bash
# Top error codes
kubectl port-forward -n spicedb svc/spicedb 9090:9090 &
curl -s http://localhost:9090/metrics | grep 'grpc_server_handled_total{.*grpc_code!="OK"' | sort -k2 -n -r | head

# AuthZEN façade behavior
kubectl logs -n app deploy/authzen-facade --tail=100 | grep -i error
```

**Common causes:** schema mismatch (caller using stale namespace), Postgres dropped connections (look for codes 14/Unavailable), datastore_uri wrong.

---

## OpenBaoLockedUsers

**Trigger:** `vault_core_locked_users > 0` for 1m.

**Diagnose + remediate:**
```bash
# Find which auth method + which user (in audit logs)
kubectl logs -n openbao openbao-0 --tail=200 | jq -c 'select(.type=="response" and .response.error)'

# Unlock (requires admin token)
bao login -method=oidc role=admin
bao write sys/locked-users/<mount>/unlock/<alias_id>
```

If the user-lockout floor is firing during routine cluster bring-up, raise the limits (`user_lockout_threshold`, `user_lockout_duration`) on the affected auth method — local-edition is rebooty and can over-trigger lockouts.

---

## OpenBaoAuditFailures

**Trigger:** any `vault_audit_log_request_failure` for 5m. **CRITICAL.**

When audit can't write, OpenBao refuses operations — every secret read/write in the cluster fails until audit recovers.

**Diagnose:**
```bash
# Quickest check — pod state and logs
kubectl describe pod -n openbao openbao-0 | tail -30
kubectl logs -n openbao openbao-0 --tail=80 | grep -i audit

# Container disk usage (audit is to STDOUT but Pod's /var/log can fill)
kubectl exec -n openbao openbao-0 -- df -h /var/log /openbao/data 2>/dev/null
```

**Remediate:** stdout audit failures are usually upstream pressure (kubelet log rotation backed up, disk full on the node). Free disk on the Docker Desktop VM; restart kubelet if needed. Once audit recovers, OpenBao operations resume.

---

## IstioTCPConnectionFailureSpike

**Trigger:** ztunnel TCP failed/opened ratio >10% for 10m.

**Diagnose:**
```bash
# AuthorizationPolicies
kubectl get authorizationpolicy -A

# ztunnel access log
kubectl logs -n istio-system -l app=ztunnel --tail=100 | grep -i deny

# Inspect a specific failing flow with istioctl (if available)
istioctl analyze --all-namespaces
```

**Common causes:** new AuthorizationPolicy missing a needed `from`, mTLS strict-mode rolled out without all peers having SVIDs, NetworkPolicy collision, target workload's pod IP changed without ztunnel refreshing (rare; `kubectl delete pod` the affected target to nudge ztunnel).
