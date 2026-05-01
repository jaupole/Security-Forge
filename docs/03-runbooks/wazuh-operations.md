# Wazuh operations runbook

> Architecture: [observability](../01-architecture/08-observability.md). Deploy: `infrastructure/wazuh/`.

Wazuh is the SecForge platform's SIEM (5th pillar). Deployed in Phase 7.2 (Session 4, 2026-05-01) using the vendored Helm chart at `infrastructure/wazuh/vendor/wazuh/` (chart `ileonelperea/wazuh-helm` v1.2.10, App 4.14.4). Path-decision rationale: see PLAN.md `### Path decision (2026-05-01)`.

## Stack at a glance

| Component | Workload | Replicas | Ports | Purpose |
|---|---|---|---|---|
| Wazuh Indexer | StatefulSet `wazuh-indexer` | 1 | 9200/9300 | OpenSearch fork — stores alerts + audit + monitoring |
| Wazuh Manager | StatefulSet `wazuh-manager` | 1 | 1514 (events), 1515 (registration), 55000 (API) | Receives + analyzes events, runs rules |
| Wazuh Dashboard | Deployment `wazuh-dashboard` | 1 | 5601 | OpenSearch Dashboards fork — UI |
| Cleanup CronJob | `wazuh-manager-cleanup` | every 2h | — | Drops orphaned monitoring/statistics indices |

URL: `https://wazuh.secforge.local/` (cert-manager-issued via `mkcert-issuer`; ingress terminates TLS, plain HTTP backend → dashboard:5601).

## First login

The four chart-managed Secrets map to **different users** — the names are easy to confuse:

| Secret | Username | Used by | Human-facing? |
|---|---|---|---|
| `wazuh-indexer-creds` | `admin` | OpenSearch superuser — **THIS is the dashboard login** | ✅ yes |
| `wazuh-dashboard-creds` | `kibanaserver` (system) | Dashboard pod's backend auth to indexer | ❌ no |
| `wazuh-api-creds` | `wazuh-wui` | Wazuh Manager REST API on port 55000 | mostly no |
| `wazuh-filebeat-creds` | `filebeat` (system) | Manager pod's filebeat → indexer log shipping | ❌ no |

**Dashboard UI login (the one you want for the browser):**

```bash
# URL:      https://wazuh.secforge.local/
# Username: admin
# Password:
kubectl get secret -n wazuh wazuh-indexer-creds -o jsonpath='{.data.password}' | base64 -d; echo
```

**Manager API login** (for `curl https://wazuh-manager:55000/...`):

```bash
# Username:
kubectl get secret -n wazuh wazuh-api-creds -o jsonpath='{.data.username}' | base64 -d; echo
# Password:
kubectl get secret -n wazuh wazuh-api-creds -o jsonpath='{.data.password}' | base64 -d; echo
```

**Why the secret names mislead.** Upstream chart names follow the OpenSearch role naming (`kibanaserver` = the dashboard pod's identity to the indexer; `filebeat` = the manager pod's filebeat sidecar's identity). The actual end-user login is the OpenSearch `admin` superuser, which lives in `wazuh-indexer-creds`. Don't trust the secret name; trust the table above.

OIDC federation against Keycloak is **not yet wired** — see `Deferred components` below.

## Deferred components

The Phase 7.2 deploy intentionally omits four pieces. Each has a clear "when to revisit" criterion.

### 1. Wazuh Agent DaemonSet — deferred to Phase 7d

**Why deferred:** the chart's agent ships with `securityContext.privileged: true` + `hostPID: true` + hostPath mounts of `/etc`, `/var/log`, `/proc`. That demands a namespace-wide PSS=`privileged` label or a per-SA exemption. The operator's call (Session 4 GREEN) was to keep the namespace at PSS=`baseline` and defer the agent rather than relax PSS for the whole stack.

**What we lose without the agent:**
- File integrity monitoring (FIM) on the host filesystem (`/etc`, `/var/log`, `/usr/bin`)
- syscheck / rootcheck against the host
- Active-response on host-level events (kill-process, block-IP)

**What we still get without the agent:**
- Forwarded-events SIEM via syslog from in-cluster sources (Keycloak event log, OpenBao audit log) into the Wazuh manager — this is the "what events reach the SIEM" path covered by the architecture doc, just sourced from the apps directly instead of from an agent watching their disk files
- All Wazuh manager rules + indexing + dashboards still apply to those forwarded events

**Revisit when:** Phase 7d. Plan: pin agent image by digest, replace `privileged: true` with `securityContext.capabilities.add: [SYS_PTRACE, AUDIT_READ, AUDIT_CONTROL]`, drop hostPID if not strictly needed, and add a `pod-security.kubernetes.io/exempt` annotation only on the agent's ServiceAccount rather than the whole namespace.

### 2. Log forwarding from Keycloak + OpenBao — deferred (small follow-up)

The 5th pillar's pass criterion is "Wazuh manager receives + indexes Keycloak/OpenBao events". Today's deploy gets the manager listening on TCP/1514; the source-side syslog config in Keycloak (`spi-events-listener-syslog-*` Quarkus options) and OpenBao (`bao audit enable syslog address=wazuh-manager.wazuh.svc:1514`) is the missing wire. Both are small, non-destructive changes. Tracked as a Phase 7.2 follow-up.

NetworkPolicy is already in place (`02-networkpolicies.yaml`'s `allow-syslog-to-wazuh-manager` allows keycloak/openbao/app namespaces to reach manager:1514).

### 3. OIDC federation with Keycloak — deferred (medium follow-up)

The dashboard authenticates via local admin password today. To federate against Keycloak:
1. Create the `wazuh-dashboard` Keycloak client (Path A pattern; mirror `infrastructure/keycloak/clients/grafana.sh`)
2. Configure the OpenSearch Security plugin (`config.yml` + `roles_mapping.yml` inside the dashboard pod) to accept OIDC tokens from Keycloak
3. Map `platform_admin` realm role → Wazuh `admin` backend role

Approach: add a `dashboard.config` values key to override `opensearch_dashboards.yml` and a separate ConfigMap for OpenSearch Security `config.yml`. Estimate: 60-90 min once we sit down for it.

### 4. Custom rules (CIS K8s, MITRE ATT&CK) — partially deferred

Wazuh manager image already ships with the CIS Kubernetes benchmark rules and MITRE ATT&CK mapping rules baked in. Without agents, those rules don't fire (they need agent-collected data). When the agent comes back in Phase 7d the rules activate automatically.

For the forwarded-events path, custom decoders for OpenBao audit JSON and Keycloak event JSON should be added. Tracked as a Phase 7.2 follow-up alongside log forwarding.

---

## Common operations

### Restart a component

```bash
kubectl rollout restart -n wazuh statefulset/wazuh-indexer    # (waits for cluster green again — slow)
kubectl rollout restart -n wazuh statefulset/wazuh-manager
kubectl rollout restart -n wazuh deployment/wazuh-dashboard
```

### Check indexer cluster health

```bash
ADMIN_PW=$(kubectl get secret -n wazuh wazuh-indexer-creds -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n wazuh wazuh-indexer-0 -- curl -sk -u "admin:$ADMIN_PW" \
    https://localhost:9200/_cluster/health | jq
kubectl exec -n wazuh wazuh-indexer-0 -- curl -sk -u "admin:$ADMIN_PW" \
    https://localhost:9200/_cat/indices?v
```

`status: green` is the target (single-replica = no `yellow` from unallocated replicas).

### Tail manager events

```bash
kubectl logs -n wazuh wazuh-manager-0 -f --tail=50
```

Wazuh manager logs everything (alerts, daemon errors, filebeat shipping status) to STDOUT; Promtail picks them up into Loki via the standard pipeline.

### Trigger a test event into the indexer

When source-side log forwarding is wired (deferred — see above), a manual flush is:

```bash
# From a pod that has the syslog allow flow (any pod in keycloak/openbao/app ns)
echo "<134>$(date +'%b %d %T') test-source: phase-7.2 verification ping" | \
    nc -w1 wazuh-manager.wazuh.svc.cluster.local 1514
# Then in Wazuh dashboard → Events → Last 15 min: should show under "test-source"
```

### Rotate the chart-managed credential Secrets

The four credential Secrets (`wazuh-{indexer,api,dashboard,filebeat}-creds`) are pre-created by `apply.sh` with random passwords meeting Wazuh's complexity policy (length 8–64, ≥1 upper / ≥1 lower / ≥1 digit / ≥1 special from `.*+?=!&|`). To rotate:

```bash
kubectl delete secret -n wazuh wazuh-{indexer,api,dashboard,filebeat}-creds
bash infrastructure/wazuh/apply.sh    # idempotent — re-creates with fresh PWs, helm-upgrades, rolls
```

**Note:** rotating the Secrets requires rolling all three workloads since they read passwords as env vars at container start.

---

## Vendored chart maintenance

- Chart vendored at `infrastructure/wazuh/vendor/wazuh/` (vendoring chosen because the chart is single-maintainer; we own the artifact).
- Patches applied to upstream are in `infrastructure/wazuh/vendor/PATCHES.md` — currently P-001 (remove `NET_RAW` from manager capabilities; PSS baseline forbids it) and P-002 (remove `workload=wazuh` nodeSelector from cleanup CronJob; we don't have those node labels).
- To bump the chart: `helm pull wazuh-eks/wazuh --version <new> --untar` into a temp dir, diff against current vendored copy, re-apply each patch from `PATCHES.md`, run `helm template` audit (CLAUDE.md bright-lines), update `.provenance`.

## Threat model + compliance

- **Wazuh manager runs as UID 0 inside the container.** Required by upstream Wazuh for syscheck / file ownership operations. `allowPrivilegeEscalation: false` and `capabilities: drop: [ALL]` (with a narrow allow list — see PATCHES.md P-001) keep the blast radius bounded.
- **Indexer + dashboard run as UID 1000 with `seccompProfile: RuntimeDefault`.** Standard PSS baseline.
- **Cluster-internal mTLS certs:** chart-generated at install, 5-year leaf / 10-year root. These are component-internal (not user/session) credentials. Phase 7d / Phase 7c flips them to cert-manager-issued 90-day rotation alongside the SPIRE-as-CA cutover.
- **Internal admin passwords:** held in K8s Secrets, never in values.yaml or git. The dashboard admin login is the only persistent credential for human access until OIDC federation lands.

## Troubleshooting

### Indexer shows YELLOW status

Single-replica setup → unallocated replica shards. Either:
- Set `index.number_of_replicas: 0` on the affected indices (the `wazuh-monitoring-*` and `wazuh-statistics-*` index templates already do this in the chart), or
- Bump indexer replicas (requires more memory; see PLAN.md memory budget notes).

### Filebeat in manager pod logs `x509: certificate signed by unknown authority`

The cert chain bootstrap ran during the helm pre-install Job and seeded `wazuh-{indexer,manager,dashboard,filebeat}-certs` Secrets. The error is typically transient at pod startup (filebeat tries to connect before security init finishes). If it persists:
```bash
kubectl get secret -n wazuh wazuh-filebeat-certs -o jsonpath='{.data.root-ca\.pem}' | base64 -d | openssl x509 -noout -text | head -20
kubectl get secret -n wazuh wazuh-indexer-certs -o jsonpath='{.data.root-ca\.pem}' | base64 -d | openssl x509 -noout -text | head -20
# Both should show the SAME root CA (same Subject + Validity).
```
If the roots differ: the cert generator was re-run between component installs; trigger a coordinated re-bootstrap by deleting all four `*-certs` Secrets + the indexer + manager + dashboard pods so the helm pre-install Job re-runs cleanly (or just reinstall the helm release).

### Dashboard `/app/login` shows TLS warning in browser

The cert-manager-issued cert chains to the mkcert local root. If your browser doesn't trust mkcert's root yet, run `mkcert -install` on the host. Same flow as Grafana / Keycloak admin URLs.

### `wazuh-manager-cleanup` Pending

Confirm vendor/PATCHES.md P-002 is applied (the chart's hardcoded `nodeSelector: workload=wazuh` removed). If you re-vendored from upstream, that patch may need to be re-applied.

### Indexer pod gets OOMKilled

Tighten the indexer JVM heap via `infrastructure/wazuh/values.yaml` → `indexer.javaOpts`. Default is `-Xms1536m -Xmx1536m`; can lower to 1024m on a memory-constrained host. Match the container `requests.memory` to the heap (50/50 rule of thumb for OpenSearch).
