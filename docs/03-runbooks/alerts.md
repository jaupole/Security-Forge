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

---

## AuthzUnavailableBurst

**Trigger:** any `AuthzUnavailableError` log line in an app namespace within a 5m window (Loki ruler rule, `15-loki-ruler-alerts.yaml`). Zero-baseline: 21 days of logs before 2026-07-15 contained none.

**Meaning:** the app's `ecosystem-authz` client could not reach SpiceDB and failed closed — affected requests returned 500. Since ecosystem-authz 0.1.2 (5s reconnect-backoff cap, retries at 500/1500/3000 ms), a transient network reset costs seconds; a burst of a few hits that stops on its own is that self-healing path working. A sustained stream means SpiceDB or the network path is actually down.

**Diagnose:**
```bash
# Scope + duration — which namespace, how many, still ongoing?
# (Grafana → Explore → Loki):
#   {namespace=~"control|member-hub|proposal-forge|project-manager|business-manager"} |= "AuthzUnavailableError"

# SpiceDB health
kubectl -n spicedb get pods
kubectl -n spicedb logs deploy/spicedb --tail=50

# If one namespace only: its NetworkPolicy path to spicedb:50051
kubectl -n spicedb get netpol | grep allow-

# Root network trigger (RCA-sso-switcher §6.6): capture BEFORE reboot/rotation
dmesg -T | tail -50
journalctl -u k3s --since "-30 min" | grep -iE 'conntrack|route|link'
```

**Remediate:** short self-terminated burst → nothing to fix, but record the timestamp; recurrence pattern is what identifies the underlying network trigger (unprovable in the 2026-07-15 incident because the journal rotated). Sustained → treat as SpiceDB outage: check pod health, CNPG primary, and `allow-<app>-to-spicedb` NetworkPolicies (a new app namespace missing its policy 500s exactly like this).

---

## AuditChainBroken

**Trigger:** any `AUDIT_CHAIN_BROKEN` log line in `control`, `proposal-forge`, `business-manager` or `project-manager` within a 15m window (Loki ruler rule, `15-loki-ruler-alerts.yaml`). Each app verifies its audit log's hash chains a few minutes after boot and every 24 hours, and logs the marker only when a chain does not verify, so the alert re-fires daily until the cause is dealt with.

**Meaning:** an audit row was changed or removed by something other than the retention purge. The audit tables are append-only for the app roles (triggers refuse UPDATE, TRUNCATE, and DELETE outside the purge), so a break means someone acted with owner or superuser access, or a migration or restore touched the table. Nothing is repaired or blocked automatically. Treat it as a possible tampering incident until explained.

**Diagnose:**
```bash
# Which chain, and the first row that fails (the log line carries the same):
#   {namespace=~"control|proposal-forge|project-manager|business-manager"} |= "AUDIT_CHAIN_BROKEN"

PSQL="kubectl exec -n ecosystem-db ecosystem-db-1 -c postgres -- psql -U postgres"

# Re-run the check by hand (empty result / NULL = intact)
$PSQL -d proposal_forge   -c "SELECT * FROM audit_log_broken_chains();"
$PSQL -d business_manager -c "SELECT * FROM business_manager.audit_logs_broken_chains();"
$PSQL -d project_manager  -c "SELECT audit.first_broken_row();"   # must run with the app's TimeZone
$PSQL -d control          -c "SELECT * FROM app_audit_events_broken_chains();"

# Compare the app's rows with the copy Control holds (the app's sealed hash as
# it was when forwarded). Example for Proposal Forge, from the broken seq on:
$PSQL -d proposal_forge -c "SELECT seq, encode(row_hash,'hex') FROM audit_log WHERE org_id = '<org>' AND seq >= <seq> ORDER BY seq LIMIT 20;"
$PSQL -d control        -c "SELECT source_seq, encode(source_row_hash,'hex') FROM app_audit_events WHERE source_app = 'proposalapp' AND org_id = '<org>' AND source_seq >= <seq> ORDER BY source_seq LIMIT 20;"
```
A hash that differs between the two means the app's row was rewritten after it was forwarded. A seq present in Control and missing in the app means the row was deleted. A break at the very start of a chain right after a purge is expected to verify cleanly; if it does not, check the purge ran inside its own rules (`purge` rows in the log).

**Remediate:** do not "fix" the chain. Record the broken row ids, who had database access in the window (CNPG and Wazuh logs), and whether a migration, restore, or manual session touched the table. If it was an operator action, document it and re-anchor deliberately. If it cannot be explained, handle as a security incident. Project Manager has an `audit.tamper_flag` that stops all audited writes when set; setting it is an operator decision and takes most of that app down.

---

## ProposalDocumentSaveFailing

**Trigger:** any `DOCUMENT_SAVE_FAILED` log line in `proposal-forge` within a 10m window (Loki ruler rule, `15-loki-ruler-alerts.yaml`). Zero-baseline: Proposal Forge logs the marker only when an editor save fails to land. It covers every failure path of `POST /api/v1/onlyoffice/callback/:projectId`: the Document Server reporting a save error (callback status 3/7), a callback whose JWT Proposal Forge rejects (403), and a Proposal Forge-side failure to download or store the saved bytes (SSRF host-lock, DS pull, docx sniff, MinIO).

**Meaning:** the proposal's document is the only place its text lives (one-place model, 2026-10-07). A save that does not reach Proposal Forge is lost work: the editor keeps its own copy only until the session ends, and the once-a-minute auto-assembly re-tries the same failing path. The affected proposal shows a save-error banner on the Document step. One hit can be a transient (a MinIO blip); a steady stream, one per minute per open document, means every save is failing — that was the shape of the 2026-07..10 callback bug (public-origin callback URL rejected 400 by the SSRF lock), which this alert exists to catch.

**Diagnose:**
```bash
# Which failure path, how many proposals, still ongoing? (Grafana → Explore → Loki)
#   {namespace="proposal-forge"} |= "DOCUMENT_SAVE_FAILED"
# The marker is followed by the path: "onlyoffice reported a save error" (DS-side),
# "callback with missing/invalid JWT rejected" (secret drift), or
# "storing the saved document failed" (PF-side; the err field says why).

# PF-side: is the DS reachable in-cluster and is MinIO healthy?
kubectl -n proposal-forge logs deploy/proposal-forge --tail=200 | grep -E 'DOCUMENT_SAVE_FAILED|DS file download|Unhandled'
kubectl -n onlyoffice get pods
kubectl -n minio get pods

# Secret drift (403 path): both sides must hold the same JWT secret
kubectl -n proposal-forge get secret onlyoffice-jwt -o jsonpath='{.data}' | jq 'keys'   # names only — never print values
kubectl -n onlyoffice logs deploy/onlyoffice --tail=100 | grep -iE 'jwt|token'

# DS-side (status 3/7): the DS's own save log
kubectl -n onlyoffice logs deploy/onlyoffice --tail=300 | grep -iE 'error|forcesave'
```

**Remediate:** fix the path, then confirm with a manual save in the editor and watch the log for `onlyoffice save callback processed`. Text typed while saves were failing is still in the open editor session: do NOT restart the Document Server or close the editor until a save succeeds. If the editor was already closed, the DS keeps the last unsaved copy in its cache and offers it on the next open ("opened from a server backup"); archived versions are in the Document step's History.
