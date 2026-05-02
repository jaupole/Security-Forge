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

### 1. Wazuh Agent DaemonSet — Phase 7d Item 5 (2026-05-02): hardening shipped, key persistence deferred

**Status:** infrastructure shipped (separate ns `wazuh-agent` with PSS=privileged), agent registers with manager + connects, but `/var/ossec/etc/client.keys` doesn't persist across pod restarts → enrollment-loop quirk prevents stable steady-state. The hardening work (Item 5's substantive ask) is complete; the persistence wiring is a known limitation tracked as a focused follow-up.

**What's in `infrastructure/wazuh-agent/`:**

- Standalone DaemonSet (NOT chart-managed — the chart's `agent.enabled` template hard-codes `privileged: true` + `hostPID: true` + hostPath, all of which PSS=baseline blocks; we rejected forking the chart in favor of cleanly separated manifests).
- New ns `wazuh-agent` with PSS=`privileged` (so hostPath mounts admit; the rest of `wazuh` ns stays PSS=`baseline`).
- Hardening: `privileged: false`; `hostPID: false`; `capabilities.add: [DAC_OVERRIDE, SETUID, SETGID]` only; image pinned by SHA256 digest; `seccompProfile: RuntimeDefault`; `fsGroup: 999` (the wazuh user's GID).
- Cross-ns NetworkPolicy: agent ns → manager:1514+1515 (events + registration).
- `pod-security.yaml` Kyverno cluster policy excludes `wazuh-agent` ns (host-path/host-pid/runAsUser=0 needs).

**What this hardening costs us:**

- **Host-level process inventory:** without `hostPID: true`, the agent only sees its own PID namespace. Process inventory scans, ptrace-based introspection, and rootcheck process scans don't catch host processes. File-based rootcheck still works.
- **Auditd integration:** would need `AUDIT_READ` (not in the baseline-allowed set; we excluded it).
- **Active-response:** disabled (would need root + more capabilities; not used on local-edition).

**Known issue: enrollment key persistence.** `/var/ossec/etc/` is mounted as an EmptyDir, so the agent's `client.keys` is wiped on pod restart. The agent's auto-enrollment then races against the manager's existing-name registration:

1. Pod restart → empty `client.keys` → agentd auto-enrolls → manager creates new agent ID with the same node name.
2. Agent's local enrollment-response handling doesn't reliably persist the key to `client.keys` (image's init quirk).
3. Subsequent re-enrollment fails with `Duplicate agent name` (manager's `<purge>yes</purge>` is gated by `<after_registration_time>1h</after_registration_time>`).

Effect: manager `agent_control -l` shows the agent as `Active`, but `wazuh-logcollector` doesn't reach steady state, and Phase 7d Item 6 pod-log events from Keycloak/OpenBao don't flow reliably until the operator intervenes.

**Recovery (manual):**

```bash
# Remove the duplicate agent ID from the manager's keys file:
kubectl exec -n wazuh wazuh-manager-0 -i -- /var/ossec/bin/manage_agents <<< $'r\n<id>\ny\nq\n'
# Restart the agent so it re-enrolls cleanly:
kubectl rollout restart -n wazuh-agent daemonset/wazuh-agent
```

**Permanent fix (Phase 7d.5 follow-up — separate from this Item 5 closure):**

- Pre-register the agent on the manager with a known name + extract the key once
- Persist as a K8s Secret in `wazuh-agent` ns
- Mount the Secret as `/var/ossec/etc/client.keys` via subPath (overrides the EmptyDir for that one file)
- DaemonSet's `spec.template.spec.containers[0].env.WAZUH_REGISTRATION_*` removed (agent uses pre-registered key, no auto-enroll)

Approximately 30–60 min of focused work. Tracked separately so the Item 5 hardening surface ships clean.

### 2. Log forwarding from Keycloak + OpenBao — Phase 7d Item 6 (2026-05-02): config in place, blocked by Item 5 stability

**Approach (vs. the original prompt's syslog path):** instead of source-side syslog forwarding (which OpenBao 2.x doesn't natively support over a network — `syslog` audit device is `/dev/log`-only), we configured the Wazuh agent's `<localfile>` blocks to tail Keycloak + OpenBao pod logs from the host's `/var/log/pods/` tree (mounted at `/host/var/log/pods/` via the agent's hostPath mount).

**Where the config lives:**

- `infrastructure/wazuh-agent/03-configmap.yaml` — `ossec-supplements.xml` includes:

```xml
<localfile>
  <log_format>json</log_format>
  <location>/host/var/log/pods/openbao_openbao-*/openbao/*.log</location>
  <label key="source">openbao</label>
</localfile>
<localfile>
  <log_format>json</log_format>
  <location>/host/var/log/pods/keycloak_keycloak-0_*/keycloak/*.log</location>
  <label key="source">keycloak</label>
</localfile>
```

The init container appends these to the agent image's default `ossec.conf`. Verified loaded at runtime: `kubectl exec -n wazuh-agent ds/wazuh-agent -c wazuh-agent -- tail /var/ossec/etc/ossec.conf` shows the localfile blocks at the bottom.

**Status:** the config is correct and in-place, but events don't reach the manager + indexer reliably until the Item 5 enrollment-loop quirk is fixed (see § 1 above). Once `client.keys` persists, `wazuh-logcollector` stays running and the localfile tailing kicks in.

**Custom decoders for the JSON formats** (originally planned manager-side at `/var/ossec/etc/decoders/local_decoder.xml`) are NOT in this commit — they're tracked as a Phase 7d.6 follow-up; until decoders land, raw JSON events ship as `wazuh-alerts` entries with `data.*` fields but without parsed Wazuh field mappings (search by `agent.labels.source: keycloak` to find them).

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
