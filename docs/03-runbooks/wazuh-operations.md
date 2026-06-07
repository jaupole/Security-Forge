# Wazuh operations runbook

> Architecture: [observability](../01-architecture/08-observability.md). Deploy: `platform/components/07-wazuh.sh`.

Wazuh is the SecForge platform's SIEM (5th pillar). Deployed in Phase 7.2 (Session 4, 2026-05-01) using the vendored Helm chart at `platform/manifests/wazuh/vendor-chart/` (chart `ileonelperea/wazuh-helm` v1.2.10, App 4.14.4). Path-decision rationale: see PLAN.md `### Path decision (2026-05-01)`.

## Stack at a glance

| Component | Workload | Replicas | Ports | Purpose |
|---|---|---|---|---|
| Wazuh Indexer | StatefulSet `wazuh-indexer` | 1 | 9200/9300 | OpenSearch fork — stores alerts + audit + monitoring |
| Wazuh Manager | StatefulSet `wazuh-manager` | 1 | 1514 (events), 1515 (registration), 55000 (API) | Receives + analyzes events, runs rules |
| Wazuh Dashboard | Deployment `wazuh-dashboard` | 1 | 5601 | OpenSearch Dashboards fork — UI |
| Cleanup CronJob | `wazuh-manager-cleanup` | every 2h | — | Drops orphaned monitoring/statistics indices |

URL: `https://wazuh.secforge.dev/` (cert-manager-issued via `mkcert-issuer`; ingress terminates TLS, plain HTTP backend → dashboard:5601).

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
# URL:      https://wazuh.secforge.dev/
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

### 1. Wazuh Agent DaemonSet — Phase 7d Item 5 (2026-05-02): hardening shipped; key persistence closed 2026-05-05 (operator-backlog #17)

**Status:** infrastructure shipped (separate ns `wazuh-agent` with PSS=privileged), agent registers with manager + connects. **`/var/ossec/etc/client.keys` persistence resolved 2026-05-05** via `bootstrap-agent-key.sh` (pre-register agent on manager → extract key → persist as K8s Secret `wazuh-agent/wazuh-agent-key`) + DaemonSet init-container injection (the etc-overlay init copies the Secret content into `/var/ossec/etc/client.keys` at every pod start, so the agent uses the pre-registered key directly and never auto-enrolls). Verified: kill the agent pod, watch the new pod come back with the SAME agent ID (010) and Active state in `agent_control -l`; manager logs show zero re-enrollment events.

**What's in `platform/manifests/wazuh-agent/`:**

- Standalone DaemonSet (NOT chart-managed — the chart's `agent.enabled` template hard-codes `privileged: true` + `hostPID: true` + hostPath, all of which PSS=baseline blocks; we rejected forking the chart in favor of cleanly separated manifests).
- New ns `wazuh-agent` with PSS=`privileged` (so hostPath mounts admit; the rest of `wazuh` ns stays PSS=`baseline`).
- Hardening: `privileged: false`; `hostPID: false`; `capabilities.add: [DAC_OVERRIDE, SETUID, SETGID]` only; image pinned by SHA256 digest; `seccompProfile: RuntimeDefault`; `fsGroup: 999` (the wazuh user's GID).
- Cross-ns NetworkPolicy: agent ns → manager:1514+1515 (events + registration).
- `pod-security.yaml` Kyverno cluster policy excludes `wazuh-agent` ns (host-path/host-pid/runAsUser=0 needs).

**What this hardening costs us:**

- **Host-level process inventory:** without `hostPID: true`, the agent only sees its own PID namespace. Process inventory scans, ptrace-based introspection, and rootcheck process scans don't catch host processes. File-based rootcheck still works.
- **Auditd integration:** would need `AUDIT_READ` (not in the baseline-allowed set; we excluded it).
- **Active-response:** disabled (would need root + more capabilities; not used on local-edition).

**Resolved persistence flow (operator-backlog #17 closeout, 2026-05-05).** `/var/ossec/etc/` is still an EmptyDir, but `client.keys` no longer comes from auto-enrollment. The init container copies the K8s Secret content into the EmptyDir, so:

1. Pod restart → init container copies pre-registered key from K8s Secret → `wazuh-control start` sees a valid `client.keys` and connects to the manager directly (no enrollment exchange).
2. Manager's `agent_control -l` shows the same agent ID (`010 desktop-control-plane`) every time.
3. `wazuh-logcollector` stays running across restarts; Phase 7d Item 6 pod-log events flow continuously.

**Bootstrap (one-time, idempotent re-runs land a fresh ID + key):**

```bash
bash platform/manifests/wazuh-agent/bootstrap-agent-key.sh
kubectl rollout restart -n wazuh-agent daemonset/wazuh-agent
```

The script registers `desktop-control-plane` with the manager, extracts the agent key, and writes the K8s Secret. Re-running registers a NEW ID + key (clean slate); existing pods pick it up on the next rollout.

**Recovery from a duplicate-agent state (only needed if Bootstrap was skipped and an auto-enrollment loop already happened):**

```bash
# Remove duplicate registrations of `desktop-control-plane` from the manager,
# then re-bootstrap:
kubectl exec -n wazuh wazuh-manager-0 -- /var/ossec/bin/manage_agents -l \
    | awk '/Name: desktop-control-plane,/ { print $2 }' | tr -d ','
# (For each ID printed, remove with `manage_agents -r <id>` — pipe `y\n` for confirmation.)
bash platform/manifests/wazuh-agent/bootstrap-agent-key.sh
kubectl rollout restart -n wazuh-agent daemonset/wazuh-agent
```

**Multi-node note:** the bootstrap script registers ONE agent (Docker Desktop's single node). Multi-node clusters need a per-node agent name + key — out of scope for local-edition.

### 2. Log forwarding from Keycloak + OpenBao — Phase 7d Item 6 (2026-05-02): config in place, blocked by Item 5 stability

**Approach (vs. the original prompt's syslog path):** instead of source-side syslog forwarding (which OpenBao 2.x doesn't natively support over a network — `syslog` audit device is `/dev/log`-only), we configured the Wazuh agent's `<localfile>` blocks to tail Keycloak + OpenBao pod logs from the host's `/var/log/pods/` tree (mounted at `/host/var/log/pods/` via the agent's hostPath mount).

**Where the config lives:**

- `platform/manifests/wazuh-agent/03-configmap.yaml` — `ossec-supplements.xml` includes:

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

**Status:** **agent → manager → indexer with secforge custom rule firing on real pod-log lines** — fully live as of 2026-05-05 (operator-backlog #17, #18, #23, #24 all closed). With `client.keys` persisting (§ 1 above), `wazuh-logcollector` stays running and the localfile tailing reaches the manager continuously; alerts.log shows real OpenBao + Keycloak events firing rules. With #23 closed, filebeat → indexer ships the alerts to `wazuh-alerts-4.x-YYYY.MM.DD` daily indices; the dashboard's Discover view populates within ~30s of an event. With #24 closed, the secforge custom rules (100300-100399 on the platform; 100200-range in the retired local edition) fire on the kubelet-wrapped JSON shape — see § "kubelet pod-log prefix handling" below for the syslog-pre-decoder quirk that bit us.

**Manager-side decoders + rules (operator-backlog #18 closeout, 2026-05-05).** The agent's `<localfile log_format="syslog">` blocks emit kubelet-wrapped pod-log lines (`<RFC3339-TS> stdout F {...json...}`); the manager's syslog pre-decoder strips the kubelet wrapper, then a custom JSON_Decoder parses the trailing JSON into named fields. Rules then match those fields and surface alerts at level ≥ 3 (Wazuh's archive-and-display threshold).

- **Decoder:** `platform/manifests/wazuh/local-decoders/openbao-keycloak-json.xml` → installed at `/var/ossec/etc/decoders/local_decoder_openbao_keycloak.xml` by `platform/components/07o-wazuh-audit-rules.sh`.
- **Rules:** `platform/manifests/wazuh/local-rules/openbao-keycloak-audit.xml` → installed at `/var/ossec/etc/rules/local_rules_openbao_keycloak_audit.xml` by `platform/components/07o-wazuh-audit-rules.sh`. Rule range 100300–100399 (renumbered from the local edition's 100200-range — that collided with Trivy's 100200-100203; see `docs/06-reference/wazuh-rule-conventions.md`). Rule shapes:
  - **OpenBao** (sentinel: `auth.display_name` + `request.path` exist): 100300 base @ level 3, 100301 auth/policy denial @ level 8, 100302/100304/100305 sensitive-write on `sys/`/`auth/jwt/`/`transit/keys/` @ level 6, 100306 read-side denial @ level 5, 100303 brute-force correlation @ level 14.
  - **Keycloak** (sentinel: `loggerName` starts with `org.keycloak`): 100320 base @ level 3, 100321 WARN @ level 5, 100322 ERROR @ level 10, 100324 FATAL @ level 12, 100323 audit-listener (`org.keycloak.events`) @ level 5.

**Wazuh rule-schema gotchas hit during the cutover (preserve here so future-you doesn't rediscover):**
1. `<field name="type">`, `<field name="level">`, `<field name="request.operation">`, `<field name="request.path">` are all reserved tag names in Wazuh's rule schema — analysisd rejects with `5107: Syntax error on tag '<name>'`. Anchor on uniquely-named decoded fields (`auth.display_name`, `loggerName`) instead, and use `<match>` (substring) for severity-style discriminators.
2. Wazuh's classic `<regex>` does NOT support `(A|B)` capture groups in child-rule contexts. Either split the rule per alternative (one `<match>` per case) or use `<regex type="pcre2">`.
3. `wazuh-logtest` (interactive: `kubectl exec -n wazuh wazuh-manager-0 -i -- /var/ossec/bin/wazuh-logtest`) is the right tool for verifying a rule fires before relying on the dashboard — it shows Phase 1 pre-decoding, Phase 2 decoded fields, Phase 3 rule match, and the alert that would be generated. **Important:** test BOTH the synthetic clean-JSON shape AND a real kubelet-wrapped line (`<RFC3339-TS> stdout F {"...":...}`) — the two go through different decoders and a rule that fires for one may not fire for the other (see § "kubelet pod-log prefix handling" below).

**kubelet pod-log prefix handling (operator-backlog #24, closed 2026-05-05):**

The wazuh-agent's `<localfile log_format="syslog">` blocks tail kubelet pod logs at `/host/var/log/pods/<ns>_<pod>_*/<container>/*.log`. Kubelet writes those files in this shape:

```
<RFC3339-timestamp> (stdout|stderr) (F|P) <payload>
```

Wazuh's syslog pre-decoder runs first and (counterintuitively) consumes BOTH the timestamp AND the `stdout` / `stderr` token — it treats `stdout`/`stderr` as the syslog HOSTNAME slot per RFC3164's `<TS> <HOSTNAME> <PROGRAM>: <MSG>` shape. So the message content reaching the decoders is **`F {"...":...}`** (full lines) or **`P {"...":...}`** (partial / continuation lines). It is NOT `{"...":...}` — the leading `F ` / `P ` is what bit us in #24.

Three `json`-named decoders handle this — the chart ships one, and `platform/manifests/wazuh/local-decoders/openbao-keycloak-json.xml` adds the other two:

| Decoder name | Prematch | Notes |
|---|---|---|
| `json` (chart-shipped) | `^{"` | Synthetic clean JSON input. `wazuh-logtest` lines without the kubelet wrapper take this path. |
| `json` (our `^F `) | `^F ` | Kubelet full-line shape. `offset="after_prematch"` aims `JSON_Decoder` at the `{` that follows the trailing space. |
| `json` (our `^P `) | `^P ` | Kubelet continuation-line shape. Rare — only fires when a single stdout write exceeds kubelet's ~16 KiB buffer. |

All three decoders are intentionally named `json` (NOT a unique custom name). Wazuh allows multiple decoders to share a name and tries them in order; rules in `openbao-keycloak-audit.xml` then key on `<decoded_as>json</decoded_as>` and fire identically regardless of which decoder did the JSON parse.

**Why `<prematch>` is restricted:**

- `<prematch>` uses Wazuh's OSRegex engine — NOT pcre2. The `type="pcre2"` attribute is only honored on `<regex>`.
- OSRegex supports top-level `|` alternation but NOT grouped alternation `(F|P)`. analysisd rejects with `(1452): Syntax error on regex: '^stdout (F|P) '`.
- OSRegex does NOT support POSIX character classes `[FP]`.
- That's why we have two literal-prefix decoders (`^F ` / `^P `) instead of one combined regex.

**If a rule fires for `wazuh-logtest` synthetic input but NOT for live pod-log events**, the breakage is almost certainly between this section and the rule — verify with this two-step test:

```bash
# Synthetic shape (chart-shipped json decoder path)
kubectl exec -n wazuh wazuh-manager-0 -i -c wazuh-manager -- /var/ossec/bin/wazuh-logtest <<'JSON'
{"time":"2026-05-05T20:38:16Z","type":"request","auth":{"display_name":"jason"},"request":{"operation":"read","path":"secret/data/foo"}}
JSON

# Real kubelet shape (our ^F decoder path) — note the literal `stdout F ` prefix
kubectl exec -n wazuh wazuh-manager-0 -i -c wazuh-manager -- /var/ossec/bin/wazuh-logtest <<'JSON'
2026-05-05T20:38:16.123456789Z stdout F {"time":"2026-05-05T20:38:16Z","type":"request","auth":{"display_name":"jason"},"request":{"operation":"read","path":"secret/data/foo"}}
JSON
```

Both should land at Phase 3 `id: '100300'`. If only the first does, our `^F ` decoder isn't loaded — check `kubectl exec -n wazuh wazuh-manager-0 -- cat /var/ossec/etc/decoders/local_decoder_openbao_keycloak.xml`.

**Read-side auth/policy denial — rule 100306 (operator-backlog #27, closed 2026-05-05):**

OpenBao audit events for *denied* requests don't carry `auth.display_name` — the audit shape on auth/policy failure emits only `auth.token_type`. That excludes them from rule 100300 (which sentinels on `auth.display_name`), so they fall through to chart's catch-all rule 100001 (`<match> ERROR </match>`, level 10, false-high — reads failing auth are diagnostic, not application-error severity).

Rule 100306 fixes this by **parenting on 100001 directly via `<if_sid>100001</if_sid>`**. When 100001 matches AND the OpenBao read-denial pattern also matches (`request.operation=^read$`, `request.path` populated, top-level `error` populated), 100306 overrides at level 5. Stand-alone parenting on 100300 doesn't work because (a) failed events lack `auth.display_name`, and (b) Wazuh fires the highest-level rule when multiple match, so a stand-alone level-5 rule loses to 100001's level 10 every time.

OSRegex gotcha (worth its own callout — bit us during #27): in `<field>` constraints, **`\.` means "any char"** and **bare `.` means "literal period"**. That inverts the PCRE convention. Use `\.+` for "any non-empty content"; use `\.+@\.+` for an email-shape match; use bare `.+` only when you actually want literal periods. The same convention applies in `<regex>` blocks. The `^read$` form (anchored literal) does work as expected — it's only the wildcards that flip.

Verify with `wazuh-logtest`:

```bash
kubectl exec -n wazuh wazuh-manager-0 -i -c wazuh-manager -- /var/ossec/bin/wazuh-logtest <<'JSON'
{"time":"2026-05-05T23:11:43Z","type":"response","auth":{"token_type":"default"},"request":{"operation":"read","path":"sys/metrics"},"error":"1 error occurred:\n\t* permission denied\n\n"}
JSON
```

Expected: Phase 3 `id: '100306'` at level 5, description `OpenBao read denied: path=sys/metrics error=...`.

**Verify ingestion end-to-end (after deploy):**

```bash
# 1. Manager has the decoder + rules.
kubectl exec -n wazuh wazuh-manager-0 -- ls -la \
    /var/ossec/etc/decoders/local_decoder_openbao_keycloak.xml \
    /var/ossec/etc/rules/local_rules_openbao_keycloak_audit.xml
kubectl exec -n wazuh wazuh-manager-0 -- bash -c \
    'grep "Total rules enabled" /var/ossec/logs/ossec.log | tail -1'
# Expected: chart-shipped total + 12 secforge rules (the 100300-range);
# a lower count means the rule file failed to load — check the next grep.
kubectl exec -n wazuh wazuh-manager-0 -- bash -c \
    'grep -E "Error loading the rules|Syntax error" /var/ossec/logs/ossec.log | tail -3'

# 2. Sanity-check rule firing without leaving the manager.
kubectl exec -n wazuh wazuh-manager-0 -i -- /var/ossec/bin/wazuh-logtest <<'JSON'
{"time":"2026-05-05T13:00:00Z","type":"request","auth":{"display_name":"jason"},"request":{"operation":"read","path":"secret/data/foo"}}
JSON
# Expected: rule 100300 fires at level 3 with description
# "OpenBao audit: actor=jason op=read path=secret/data/foo".

# 3. End-to-end (operator hits Keycloak + OpenBao, alerts land in dashboard).
curl -sk https://auth.secforge.dev/realms/secforge-tenants/.well-known/openid-configuration >/dev/null
kubectl exec -n openbao openbao-0 -- bao kv get secret/foo 2>/dev/null
# Then in Wazuh dashboard, Discover view: filter `rule.id: 100300 OR rule.id: 100320`.
```

### 3. OIDC federation with Keycloak — deferred (medium follow-up)

The dashboard authenticates via local admin password today. To federate against Keycloak:
1. The `wazuh-dashboard` Keycloak client is codified in the realm-import (`platform/manifests/keycloak/realms/platform-realm.yaml`); add/adjust it there and re-apply (admin is DB-only — no kcadm)
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

### End-to-end verification recipe (real-event ingestion probe)

The runbook's earlier "Verify ingestion end-to-end (after deploy)" block under § "Log forwarding from Keycloak + OpenBao" uses `wazuh-logtest` for a **synthetic** rule-firing check. That confirms the manager parses + matches; it does NOT confirm the agent → manager → indexer pipeline carries real events to the indexer. This recipe is the canonical "is the SIEM actually getting events" probe — run it before declaring SIEM coverage healthy:

```bash
# 1. Snapshot the start time (UTC; events emitted before this are filtered out).
TS_BEFORE=$(date -u +%Y-%m-%dT%H:%M:%SZ); echo "$TS_BEFORE"

# 2. Trigger Keycloak audit events (1 well-known fetch + 3 failed logins → LOGIN_ERROR).
curl -sk -o /dev/null -w 'HTTP %{http_code}\n' \
    https://auth.secforge.dev/realms/secforge-tenants/.well-known/openid-configuration
for i in 1 2 3; do
    curl -sk -o /dev/null -w 'HTTP %{http_code}\n' \
        -X POST https://auth.secforge.dev/realms/secforge-tenants/protocol/openid-connect/token \
        -d "grant_type=password&client_id=helloworld-bff&username=wrong-user&password=wrong-pw-$i"
done

# 3. Trigger an OpenBao audit event (read + write).
SA_JWT=$(kubectl exec -n openbao openbao-0 -c openbao -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
ADMIN_TOKEN=$(kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 \
    bao write -format=json auth/kubernetes/login role=admin-break-glass jwt="$SA_JWT" \
    | jq -r '.auth.client_token')
kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ADMIN_TOKEN" \
    bao kv get secret/spicedb/preshared-key   # read
kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ADMIN_TOKEN" \
    bao kv put secret/test/wazuh-verify ts="$TS_BEFORE" trigger=verify-recipe   # write

# 4. Wait for the agent → manager → indexer pipeline to flush.
sleep 30

# 5. Query the indexer for secforge-custom rule hits since TS_BEFORE.
WAZUH_PW=$(kubectl get secret -n wazuh wazuh-indexer-creds -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n wazuh wazuh-indexer-0 -c wazuh-indexer -- curl -sk -u "admin:$WAZUH_PW" \
    "https://localhost:9200/wazuh-alerts-*/_search?pretty" \
    -H 'Content-Type: application/json' \
    -d "{
      \"query\":{\"bool\":{\"must\":[
        {\"range\":{\"@timestamp\":{\"gte\":\"$TS_BEFORE\"}}},
        {\"range\":{\"rule.id\":{\"gte\":100300,\"lte\":100399}}}
      ]}},
      \"size\":5,
      \"_source\":[\"@timestamp\",\"rule.id\",\"rule.description\",
                   \"data.auth.display_name\",\"data.request.operation\",\"data.request.path\",
                   \"data.loggerName\",\"data.message\",\"agent.name\"]
    }" | jq '.hits | {total: .total.value, ids: [.hits[]._source["rule.id"]] | unique}'
# Expected (post-#24 closeout, real-event coverage live):
#   total >= 2; ids include at least one OpenBao rule (100300-100309) and
#   one Keycloak rule (100320-100329) within the TS_BEFORE..now window.
# This is the canonical "secforge-specific SIEM coverage live" closure
# signal — narrower than "any wazuh-alerts hits" (which can be satisfied
# by chart-shipped rule 100001 catching error keywords). If total > 0
# but the rule.id range is wrong, see § "kubelet pod-log prefix handling"
# above — almost always a decoder-path issue.
```

**Diagnostic decision tree** (when step 5 returns `total: 0`):

```
Is `wazuh-alerts-*` index present at all?
    kubectl exec -n wazuh wazuh-indexer-0 -c wazuh-indexer -- \
        curl -sk -u admin:$WAZUH_PW https://localhost:9200/_cat/indices?v | grep wazuh-alerts
  ├─ No: filebeat → indexer is broken. Check:
  │      kubectl exec -n wazuh wazuh-manager-0 -c wazuh-manager -- \
  │          /usr/share/filebeat/bin/filebeat -c /etc/filebeat/filebeat.yml test output
  │      Common failure: x509 (see § Troubleshooting), empty admin password,
  │      missing ssl.* config block in /etc/filebeat/filebeat.yml output.elasticsearch.
  │      (See operator-backlog #23 for the active instance of this gap.)
  └─ Yes: pipeline OK; either (a) rule didn't match real event shape, or (b) agent
         didn't see the source log. Check:
            kubectl exec -n wazuh wazuh-manager-0 -- \
                tail -50 /var/ossec/logs/alerts/alerts.log
         If alerts ARE there, your indexer-side query syntax is the issue.
         If NOT, drop to wazuh-logtest with a representative line from the
         pod log to confirm the rule pattern matches.
```

### Rotate the chart-managed credential Secrets

The four credential Secrets (`wazuh-{indexer,api,dashboard,filebeat}-creds`) are pre-created by `platform/components/07-wazuh.sh` with random passwords meeting Wazuh's complexity policy (length 8–64, ≥1 upper / ≥1 lower / ≥1 digit / ≥1 special from `.*+?=!&|`). To rotate:

```bash
kubectl delete secret -n wazuh wazuh-{indexer,api,dashboard,filebeat}-creds
bash platform/components/07-wazuh.sh   # idempotent — re-creates with fresh PWs, helm-upgrades, rolls
```

**Note:** rotating the Secrets requires rolling all three workloads since they read passwords as env vars at container start.

---

## Vendored chart maintenance

- Chart vendored at `platform/manifests/wazuh/vendor-chart/` (vendoring chosen because the chart is single-maintainer; we own the artifact).
- Patches applied to upstream are in `platform/manifests/wazuh/vendor-chart/PATCHES.md` — currently P-001 (remove `NET_RAW` from manager capabilities; PSS baseline forbids it) and P-002 (remove `workload=wazuh` nodeSelector from cleanup CronJob; we don't have those node labels).
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

There are two distinct causes for this error — diagnose by comparing CA fingerprints first.

**Step 1 — compare the CA roots:**
```bash
kubectl get secret -n wazuh wazuh-filebeat-certs -o jsonpath='{.data.root-ca\.pem}' | base64 -d | openssl x509 -noout -fingerprint -sha256
kubectl get secret -n wazuh wazuh-indexer-certs  -o jsonpath='{.data.root-ca\.pem}' | base64 -d | openssl x509 -noout -fingerprint -sha256
```

**Case A — fingerprints differ (CA mismatch):** the cert generator was re-run between component installs. Trigger a coordinated re-bootstrap by deleting all four `*-certs` Secrets + the indexer + manager + dashboard pods so the helm pre-install Job re-runs cleanly (or just reinstall the helm release).

**Case B — fingerprints match:** the certs are fine; filebeat just isn't being told to use them. Check the rendered config:
```bash
kubectl exec -n wazuh wazuh-manager-0 -c wazuh-manager -- grep -A 7 'output.elasticsearch:' /etc/filebeat/filebeat.yml
```
A working config has all four ssl directives uncommented (see § "Filebeat output config — rendered, not chart-defaulted" below). If they're commented out (`#ssl.verification_mode:`, etc.) and `password:` is empty, that's the operator-backlog #23 shape — the image's `/etc/cont-init.d/1-config-filebeat` aborted mid-script because a sed-meta character (`|`, `&`) in `INDEXER_PASSWORD` broke the substitution. Fix: ensure the credential Secrets were generated by the post-2026-05-05 `apply.sh` (which excludes `|` / `&` from the password specials); if not, rotate per § "Rotate the chart-managed credential Secrets" — the `apply.sh` regenerates with sed-safe specials.

### Filebeat output config — rendered, not chart-defaulted

The chart's `wazuh-manager-config` ConfigMap ships a clean `filebeat.yml` with all four ssl directives + `username: '${FILEBEAT_USERNAME}'` + `password: '${FILEBEAT_PASSWORD}'` env-var refs, AND the chart's `inject-filebeat-config` initContainer copies that file into the EmptyDir mounted at `/etc/filebeat`. **However**, the Wazuh manager image's own `/etc/cont-init.d/1-config-filebeat` then runs `sed -i` against `/etc/filebeat/filebeat.yml` to replace `username:` / `password:` / `ssl.*` lines with values from the `INDEXER_*` and `SSL_*` env vars set on the manager container. The image's sed effectively wins over the chart's clean template — the resulting on-disk config has:

```yaml
output.elasticsearch:
  hosts: [https://wazuh-indexer.wazuh.svc.cluster.local:9200]
  username: 'admin'                                  # from INDEXER_USERNAME (NOT FILEBEAT_USERNAME)
  password: '<rendered INDEXER_PASSWORD>'            # from INDEXER_PASSWORD
  ssl.verification_mode: 'certificate'
  ssl.certificate_authorities: ['/etc/ssl/root-ca.pem']
  ssl.certificate: '/etc/ssl/filebeat.pem'
  ssl.key: '/etc/ssl/filebeat-key.pem'
```

Two consequences worth knowing:

1. **Filebeat auths to the indexer as the `admin` superuser, not as the dedicated `filebeat_internal` user the chart intended.** Functional but over-privileged; cluster-internal mTLS keeps the blast radius bounded. Future fix would be a fork of the cont-init script to use FILEBEAT_USERNAME instead.
2. **The image's sed uses `|` as the substitution delimiter,** so `INDEXER_PASSWORD` / `FILEBEAT_PASSWORD` MUST NOT contain `|` (delimiter) or `&` (replacement metacharacter). `platform/components/07-wazuh.sh` `gen_pw()` enforces this — `specials = ".*+?=!"`. If you bypass that script and create the secrets manually, exclude those chars yourself or expect the operator-backlog #23 failure mode to recur.

### Dashboard `/app/login` shows TLS warning in browser

The cert-manager-issued cert chains to the mkcert local root. If your browser doesn't trust mkcert's root yet, run `mkcert -install` on the host. Same flow as Grafana / Keycloak admin URLs.

### `wazuh-manager-cleanup` Pending

Confirm `platform/manifests/wazuh/vendor-chart/PATCHES.md` P-002 is applied (the chart's hardcoded `nodeSelector: workload=wazuh` removed). If you re-vendored from upstream, that patch may need to be re-applied.

### Indexer pod gets OOMKilled

Tighten the indexer JVM heap via `platform/values/wazuh.yaml` → `indexer.javaOpts`. Default is `-Xms1536m -Xmx1536m`; can lower to 1024m on a memory-constrained host. Match the container `requests.memory` to the heap (50/50 rule of thumb for OpenSearch).
