# Phase 7c — Istio SPIRE-as-CA cutover + PeerAuthentication STRICT

> **Navigation:** ⬅ [Previous: Phase 7 — Observability](./phase-07-observability.md) · [Next: Phase 8 — Teleport](./phase-08-teleport.md) ➡ · [📋 PLAN.md](../../PLAN.md) · [Phase prompts index](./README.md)
>
> **Depends on (must be ✅):** Phase 7 ✅ (Loki + Tempo make the cutover observable as it lands)
> **Blocks:** Cloud migration (cannot ship with two trust domains) — not a phase but a hard pre-cloud gate
>
> **Status (mirrors PLAN.md, last updated 2026-05-01):** ⬜ Not started. Absorbs the per-namespace AuthorizationPolicy work deferred from Fix-after-07 §B.2 (per Option C, 2026-05-01). Companion runbook: [`docs/03-runbooks/istio-peer-auth-tighten.md`](../03-runbooks/istio-peer-auth-tighten.md).
>
> PLAN.md is the source of truth for phase status. If this block diverges from PLAN.md's quick-ref table, **PLAN.md wins**; update this block in the same edit that bumps PLAN.md.

**Estimated time:** 1-2 days

**Prerequisites:** Phase 7 complete (Loki + Tempo are what makes this cutover observable as it lands; without them you're flying blind through a mesh-wide identity swap).

---

## Goal of this phase

Replace Istio Ambient's built-in Citadel CA with SPIRE-issued workload SVIDs so the entire platform speaks one trust domain (`spiffe://secforge.local/...`). In the same change window, tighten PeerAuthentication from PERMISSIVE to STRICT.

The two changes are paired deliberately. STRICT only becomes safe once every legitimate caller is mesh-resident or covered by an explicit AuthorizationPolicy ALLOW, and validating that inventory is itself easier once the mesh and the rest of the platform share one trust domain (no more "is this principal `spiffe://cluster.local/...` or `spiffe://secforge.local/...`?" double-checking).

This is the most fragile phase since Phase 6. Read [ADR-0010](../02-decisions/0010-istio-ambient-vs-sidecar.md) end-to-end before starting — it documents the original deferral and the realistic 1-2 day fiddle factor. The original ADR proposed using `cert-manager-csi-driver-spiffe` as the SPIRE bridge; that was a misread (the chart is not actually a SPIRE bridge, it issues from its own cert-manager Issuer). The genuine wiring uses spire-server's Workload API socket mounted into istiod, ztunnel, istio-cni, and the csi-driver pods.

---

## What you (the human) need to do first

1. Confirm Phase 7 is complete and Loki + Tempo are healthy. The Phase 7c.0 design checks below depend on querying both.
2. Re-read [ADR-0010](../02-decisions/0010-istio-ambient-vs-sidecar.md), specifically the "Deferred: SPIRE as Istio's CA" and "Phase 6.2b commitments" sections. The ADR is the spec; this prompt is the execution playbook.
3. Confirm SPIRE is healthy: `kubectl get pods -n spire` shows `spire-server` and `spire-agent` Running, and `kubectl exec -n spire spire-server-0 -- /opt/spire/bin/spire-server entry show` returns the entries you expect for existing workloads.
4. Pin the Istio version. ADR-0010 mandates ≥ 1.24 for Ambient + external-CA; verify `istioctl version --short` and record the version in the cutover commit message.
5. Take a fresh backup of the cluster's AuthorizationPolicy resources before any rewrite: `kubectl get authorizationpolicy -A -o yaml > /tmp/authz-pre-7c-$(date +%Y%m%d).yaml`. This is your rollback baseline.
6. Decide and write down (in the cutover commit message) which rollback strategy you're picking — see Phase 7c.0 step 4 below.

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code.

---

```
We're starting Phase 7c of the SecForge Local Edition platform build. Read CLAUDE.md, PLAN.md, docs/02-decisions/0010-istio-ambient-vs-sidecar.md, and docs/05-claude-code-prompts/phase-07c-istio-spire-ca-and-strict.md before doing anything.

Your task is to cut Istio Ambient over from its built-in Citadel CA to SPIRE-issued workload SVIDs (collapsing the platform to one trust domain `spiffe://secforge.local/...`) AND tighten PeerAuthentication from PERMISSIVE to STRICT. These two changes share a window because STRICT only becomes safe once every legitimate caller is mesh-resident or covered by an explicit AuthorizationPolicy ALLOW under the unified trust domain.

This is the most fragile phase since Phase 6. Do NOT skip Phase 7c.0. The pre-flight design checks are gating — if any fail, stop and reconsider before writing cutover code.

## Phase 7c.0 — Pre-flight design checks (gating)

Run all four checks below BEFORE any cutover code. Each check produces an artifact you'll reference later in the phase. If a check produces an unexpected result, stop and reconsider rather than working around it.

### 7c.0.1 — Confirm AuthorizationPolicy denials are visible in Loki

Trigger a known denial against today's PERMISSIVE+default-deny posture (e.g., `kubectl run -n app curl-test --image=curlimages/curl --rm -it -- curl -sv http://spicedb.spicedb.svc.cluster.local:50051` from a pod with no SPIFFE ID matching the SpiceDB AuthorizationPolicy). Then query Loki via Grafana for the denial event.

Capture and commit (to docs/03-runbooks/istio-strict-cutover.md, created in this phase) the exact LogQL query that surfaces denials. Likely shape: `{namespace="istio-system"} |= "RBAC: access denied"` or `{app="ztunnel"} | json | response_code="403"`. Verify against Phase 7 observability data — do NOT guess the label set, query Promtail's actual scrape output for ztunnel logs and confirm what fields are indexed.

If denials are NOT visible in Loki: stop. Without visibility, the STRICT flip is unrecoverable when something breaks. Fix the Promtail config first (likely scope into Phase 7b/7 follow-up territory) and come back.

### 7c.0.2 — Confirm ztunnel logs show current SPIFFE-IDs

`kubectl logs -n istio-system -l app=ztunnel --tail=200 | grep -E "spiffe://"` should show the current `spiffe://cluster.local/ns/{ns}/sa/{sa}` pattern issued by Istio's built-in CA (this is the pre-cutover state per ADR-0010). Capture a representative log line in the runbook so post-cutover verification has a concrete before/after comparison: post-cutover the same log line shape must show `spiffe://secforge.local/...`.

If you cannot find SPIFFE-ID strings in ztunnel logs at all, the log level may be too low. Bump ztunnel log verbosity (`istioctl install --set values.global.logging.level=ztunnel:debug` or equivalent for your install method) and re-run before continuing.

### 7c.0.3 — Inventory non-mesh callers

Identify every legitimate caller into the mesh-resident namespaces (`app`, `keycloak`, `spicedb`, `openbao`) that is NOT itself a mesh-resident workload. This is the inventory STRICT will break if missed.

Method: pull the last 24h of access logs for each namespace from Loki, group by source IP/principal, and classify each unique caller. Likely entries:

- ingress-nginx → BFF (`helloworld-bff`, eventually proposal-forge-bff/project-tracker-bff/pm-bff)
- kubelet → various pods for liveness/readiness/startup probes
- openbao (mesh) → postgres CNPG cluster (NOT in mesh — CNPG operator-managed pods aren't ambient-captured today)
- external browser → keycloak admin URL (`kc-admin.secforge.local`)
- external browser → bao UI / wazuh-dashboard / grafana / app
- prometheus → ServiceMonitor scrape targets across all namespaces
- promtail → STDOUT scraping (kubelet-mediated, not direct caller, but document)
- VSO (`vault-secrets-operator` namespace) → openbao API
- spire-agent → spire-server (cross-namespace, mesh status TBD — check)

For each entry: record (a) the source identity today, (b) the destination, (c) the current auth path (cleartext + NetworkPolicy / mTLS-without-AuthorizationPolicy / AuthorizationPolicy ALLOW), (d) the post-STRICT auth path (in-mesh now / explicit AuthorizationPolicy ALLOW added in 7c.3 / out-of-mesh with PERMISSIVE carve-out via per-port PeerAuthentication).

Commit the inventory table to docs/03-runbooks/istio-strict-cutover.md before proceeding. If the table has any "unknown" rows, stop and investigate — those are the rows that break STRICT.

### 7c.0.4 — Pick the rollback strategy

Two viable strategies. Pick one explicitly and write the choice (with rationale) into the runbook AND the cutover commit message:

**A. Namespace-by-namespace gradual cutover.** Apply SPIRE-as-CA + STRICT to one namespace at a time, verifying end-to-end before moving on. Order suggestion: `app` (where helloworld-bff lives — most observable failure mode) → `spicedb` → `openbao` → `keycloak` last (highest blast radius if it breaks). Pro: small blast radius per step, easy rollback. Con: spans multiple sittings; interim state has mixed trust domains, which is the same situation we're trying to escape.

**B. All-at-once with a feature-flag-style flip.** Stage all changes (Istio Helm values, AuthorizationPolicy rewrites, PeerAuthentication STRICT) on a branch, apply in a single `helm upgrade` + `kubectl apply` window, watch Tempo and Loki for breakage, roll back with the pre-7c backup if anything goes red. Pro: short interim-state window (minutes, not days). Con: large blast radius; harder to isolate which change caused a specific failure.

For the local edition the recommendation is **A** if it's your first time doing this, **B** if you've done a SPIRE-as-CA cutover before. Document the choice; do not switch strategies mid-flight.

## Phase 7c.1 — SPIRE-as-CA wiring

Reference: https://istio.io/latest/docs/ops/integrations/spire/ . That doc is sidecar-oriented; the Ambient mapping is partially documented and partially derived from how istio-cni + ztunnel consume the SPIRE Workload API. Do NOT assume blindly — for each component below, verify the volume mount and SDS configuration against the actual Istio version's manifests after `helm template` rendering.

Components that need the SPIRE Workload API socket mounted at `/run/spire/agent-sockets/spire-agent.sock` (or wherever your spire-agent DaemonSet exposes it — check via `kubectl describe daemonset spire-agent -n spire | grep hostPath`):

- istiod
- ztunnel (DaemonSet)
- istio-cni-node (DaemonSet)

For each, add:

1. A `ClusterSPIFFEID` resource in `istio-system` selecting the component's pods and minting an SVID like `spiffe://secforge.local/ns/istio-system/sa/<component-sa>`.
2. A volume mount of the spire-agent socket into the pod (HostPath or via `csi.spiffe.io` driver — match whatever the rest of the platform uses; do NOT introduce a new mount style).
3. Helm values pointing the component at the SPIRE socket as the SDS source. The Ambient-specific keys are in flux across Istio releases — `helm show values istio/istiod` and `helm show values istio/ztunnel` for your pinned version, then map per the istio.io/spire integration doc.

Disable the built-in Citadel CA: in the istiod Helm values, set `pilot.env.ENABLE_CA_SERVER=false` (or the equivalent for your Istio version — verify against `helm show values` output, do not guess). The mesh now relies entirely on SPIRE for SVIDs.

NOTE on `cert-manager-csi-driver-spiffe`: ADR-0010 originally proposed this as the bridge. It is NOT. The chart issues SPIFFE-formatted certs from a cert-manager Issuer of its own; it does not consult SPIRE. If the existing cluster has it installed, leave it for now — Phase 7c.6 reviews whether to remove it once SPIRE-as-CA is verified working.

Verify pre-restart: `kubectl get clusterspiffeids -n istio-system` shows the new entries; `kubectl exec -n spire spire-server-0 -- /opt/spire/bin/spire-server entry show` confirms entries for the istio components have been picked up. Then restart istiod, ztunnel, istio-cni in that order.

Verify post-restart against the 7c.0.2 baseline: ztunnel logs now show `spiffe://secforge.local/...` for new connections. Existing connections may still carry old `cluster.local` IDs until they re-handshake — force one by deleting a workload pod and watching it come back.

## Phase 7c.2 — Trust-domain rewrite in AuthorizationPolicy resources

Mechanical rewrite of `spiffe://cluster.local/...` → `spiffe://secforge.local/...` across all AuthorizationPolicy resources in `app`, `keycloak`, `spicedb`, `openbao`, `istio-system` namespaces.

Method: for each repo path that contains an AuthorizationPolicy YAML, sed-replace the trust domain string. DO NOT do this with `kubectl patch` against live resources — go through the manifests in `infrastructure/` so the change is committed.

After the rewrite, re-apply each affected manifest (or run the namespace's deploy script). Then verify: `kubectl get authorizationpolicy -A -o yaml | grep "spiffe://cluster.local"` should return zero matches. `kubectl get authorizationpolicy -A -o yaml | grep "spiffe://secforge.local" | wc -l` should match the count of rewritten principals.

Don't forget to scan for SPIFFE-ID references in:

- ServiceEntry resources (rare but possible if any external-mTLS targets exist)
- DestinationRule resources (if any pin a specific SAN/principal)
- RequestAuthentication resources (jwks issuers — usually URLs not SPIFFE-IDs, but check)

If the rollback strategy is A (namespace-by-namespace), do this step per-namespace in the same window as that namespace's PeerAuthentication flip (7c.4). If the strategy is B (all-at-once), do all rewrites together.

## Phase 7c.3 — Explicit ALLOW policies for non-mesh callers

For each "non-mesh caller" entry from the 7c.0.3 inventory, write an AuthorizationPolicy that explicitly ALLOWs the post-STRICT auth path. Commit each to `infrastructure/istio/authorizationpolicies/` with a filename naming the caller and target.

Likely entries (verify against your actual 7c.0.3 inventory — these are common, not exhaustive):

- `ingress-nginx-to-bff.yaml` — match on source `ipBlocks` (the ingress-nginx pod CIDR) or, preferably, source `principals` once ingress-nginx is itself mesh-resident; allow to `helloworld-bff` (and the other 3 BFFs once they exist) on the BFF's HTTPS port.
- `kubelet-probes.yaml` — apply per-namespace, allow the kubelet probe path. Strategy: a per-port PeerAuthentication carve-out (PERMISSIVE for the readiness/liveness port only) is usually cleaner than an AuthorizationPolicy ALLOW because kubelet has no SPIFFE identity. Document the tradeoff in the runbook.
- `openbao-to-postgres.yaml` — openbao (mesh-resident, has SPIFFE ID) reaching the CNPG postgres pods (NOT mesh-resident). Two paths: (a) leave the postgres pods out of mesh and rely on NetworkPolicy + Postgres TLS, OR (b) ambient-capture the postgres namespace and write an explicit AuthorizationPolicy. Local edition recommendation: (a) — postgres-side mTLS via CNPG is already strong, and dragging CNPG into Ambient adds operator-injection complexity. Document the choice.
- `prometheus-scrape.yaml` — prometheus (in `monitoring`) scraping ServiceMonitor targets across all namespaces. Allow source principal `spiffe://secforge.local/ns/monitoring/sa/kube-prometheus-stack-prometheus` to /metrics endpoints across the platform.
- `vso-to-openbao.yaml` — VSO (in `vault-secrets-operator` namespace) reaching openbao. Either ambient-capture the VSO namespace (preferred if it works without breaking VSO's controller pod) or explicit ALLOW on openbao's API port for the VSO source IP block.

For each, document in `docs/03-runbooks/istio-strict-cutover.md` what the policy authorizes and why. The runbook becomes the auditable inventory of "every allowed cross-trust-boundary call."

## Phase 7c.4 — PeerAuthentication STRICT flip

Apply STRICT mode to PeerAuthentication in each affected namespace. Today's PERMISSIVE was set in Phase 6.2; the resource lives in `infrastructure/istio/peerauthentication/` (or wherever Phase 6 committed it).

Per the chosen rollback strategy:

- Strategy A: flip one namespace at a time. After each flip, watch Tempo for traces showing rejected connections AND watch Loki using the 7c.0.1 query. Wait at least 10 minutes per namespace before moving on (kubelet probes have long-tail retry intervals; ServiceMonitor scrapes happen on 30-60s cadence). If a rejection appears, that's a 7c.3 inventory miss — fix the missing ALLOW, do NOT silently mark it expected.
- Strategy B: flip all namespaces in a single `kubectl apply`, then watch the same Tempo + Loki queries for 30 minutes. Roll back at the first unexplained rejection.

Verify the STRICT posture is actually in effect: `kubectl exec -n app -c istio-proxy <some-pod> -- curl -s http://localhost:15000/config_dump | jq '.configs[] | select(.["@type"] | contains("Listener")) | .. | .transport_socket?' | grep -i tls` (Ambient has no per-pod sidecar, so the actual verification is via ztunnel: `kubectl exec -n istio-system <ztunnel-pod> -- ...` — the exact incantation depends on the Istio version and is best confirmed via Istio's official "verify mTLS" docs). Verify against Phase 7 observability data — do NOT trust a single command output, cross-check Tempo span tags showing `tls.mode=STRICT` on inbound connections.

## Phase 7c.5 — End-to-end verification

The post-cutover smoke test. Each of these MUST pass before declaring 7c done:

1. **Browser → BFF → Keycloak → AuthZEN → SpiceDB end-to-end.** Open `https://app.secforge.local`, complete a login (passkey or TOTP per current Phase 5 / 6.10b state), trigger a CheckPermission via the helloworld backend stub. The flow should complete with a 200 response. Verify in Tempo that the trace shows all hops with `tls.mode=STRICT` and `principal=spiffe://secforge.local/...`.

2. **`infrastructure/spicedb/check-permissions.sh` still passes.** Run it; all assertions should still come back as expected. Note the parser flake from Phase 5 follow-up #5 — if it surfaces, work around per that follow-up's notes.

3. **Wazuh-via-OIDC login still works.** Open `https://wazuh.secforge.local`, complete the OIDC login. Wazuh dashboard reaches Keycloak through the mesh — if the cutover broke that, AuthorizationPolicy on Keycloak's listener is missing the wazuh-dashboard caller's new SPIFFE-ID.

4. **Grafana-via-OIDC login still works.** Same as Wazuh.

5. **`bao login -method=oidc` still works** from the WSL host (per Phase 7.0.c's CLI redirect URI fix). The OIDC flow goes via the host browser, not the mesh, so this is mostly a regression check that nothing about Keycloak's external-facing path got hit.

6. **No spurious denials in Loki for 1 hour.** Re-run the 7c.0.1 LogQL query over the last hour. Zero new RBAC denials (other than the ones you deliberately triggered as test traffic).

If any of these fail, jump to 7c.6.

## Phase 7c.6 — Rollback procedure

If STRICT breaks something mid-flight, roll back FAST — don't try to debug under STRICT. The recovery sequence:

1. **Revert PeerAuthentication to PERMISSIVE first.** This immediately restores any broken non-mesh caller. `kubectl apply -f /tmp/authz-pre-7c-<date>.yaml` or, more surgically, `kubectl patch peerauthentication default -n <namespace> --type=merge -p '{"spec":{"mtls":{"mode":"PERMISSIVE"}}}'` per affected namespace.

2. **Verify the broken thing is now working again.** Browser login, CheckPermission, etc. If PERMISSIVE doesn't fix it, the breakage is in 7c.1 (SPIRE-as-CA wiring) not 7c.4 (STRICT). In that case, also revert Istio Helm values to re-enable the built-in CA: `helm upgrade istiod ... --reset-values --reuse-values` with the original CA flag.

3. **Investigate.** Use Loki + Tempo to identify which caller was rejected. Check the 7c.0.3 inventory — was it missed? Was the AuthorizationPolicy ALLOW written incorrectly (wrong principal, wrong port, wrong namespace match)?

4. **Re-attempt with the missing ALLOW added.** Apply the fix to 7c.3, then redo 7c.4 for the affected namespace.

DO NOT try to "patch forward" by adding the ALLOW under STRICT — under STRICT the broken thing is already failing user-visibly, and the patching-forward sequence has more failure modes (typo in the new policy, ordering issues, AuthorizationPolicy reconciliation lag) than reverting + re-applying does.

## Phase 7c.7 — Documentation and ADR update

1. Update `docs/01-architecture/07-service-mesh.md`: the trust domain story is now uniform; remove the "two trust domains coexist" section and replace with the post-cutover state.
2. Update `docs/03-runbooks/istio-strict-cutover.md` (created in 7c.0): finalize the inventory table, the LogQL queries, the rollback strategy chosen, and any 7c.6-style breakages encountered.
3. Update `docs/03-runbooks/spire-rotation.md`: SPIRE is now also Istio's CA — note the operational implication that SPIRE downtime now stops new mesh connections from establishing (issued SVIDs continue to work for their TTL).
4. Update [ADR-0010](../02-decisions/0010-istio-ambient-vs-sidecar.md) status from "Accepted (with deferral)" to "Accepted (deferral resolved Phase 7c)". Add a brief postscript section noting the actual implementation date and any deviations from the original Phase 6.2b commitments.
5. Update PLAN.md: mark Phase 7c ✅ with the completion date.

## Constraints

- Do NOT introduce new tools beyond what PLAN.md and CLAUDE.md commit to (Istio, SPIRE, cert-manager-csi-driver-spiffe-if-already-present).
- Do NOT skip Phase 7c.0. The pre-flight checks are gating.
- Do NOT use `--otp` in any kcadm operation (Keycloak 26.x kcadm has no --otp flag — see PLAN.md Phase 3 follow-up). If a kcadm operation is needed in this phase (likely none, but if so), use the service-account pattern from `infrastructure/keycloak/spike-token-exchange.sh`.
- Do NOT disable certificate verification anywhere. ADR-0010's whole point is one trust domain end-to-end.
- Do NOT tighten PeerAuthentication and rewrite AuthorizationPolicy principals in different commits. They share a window because the mesh's running config has to be consistent at every moment.
```

---

## Success criteria

- [ ] Phase 7c.0 design checks all pass; runbook seeded with LogQL queries, ztunnel log baseline, non-mesh caller inventory, and rollback strategy choice
- [ ] SPIRE-as-CA wiring complete; istiod, ztunnel, istio-cni issuing identities from `spiffe://secforge.local/...`
- [ ] Built-in Citadel CA disabled; `helm get values istiod` confirms `ENABLE_CA_SERVER=false` (or version-specific equivalent)
- [ ] AuthorizationPolicy resources in app/keycloak/spicedb/openbao/istio-system rewritten; zero matches for `spiffe://cluster.local/` in `kubectl get authorizationpolicy -A -o yaml`
- [ ] AuthorizationPolicy ALLOWs committed for every entry in the 7c.0.3 inventory
- [ ] PeerAuthentication STRICT applied across all relevant namespaces; verified via ztunnel/Tempo
- [ ] End-to-end: browser → BFF → Keycloak → AuthZEN → SpiceDB works under STRICT
- [ ] `infrastructure/spicedb/check-permissions.sh` passes
- [ ] Wazuh + Grafana OIDC logins work; `bao login -method=oidc` works
- [ ] No spurious RBAC denials in Loki for at least 1 hour post-cutover
- [ ] ADR-0010 status updated; PLAN.md updated; runbooks committed

---

## Troubleshooting

### "ztunnel logs still show `spiffe://cluster.local/...` after restart"

Either the SPIRE entry for the ztunnel SA hasn't been picked up (check `spire-server entry show`) or istiod is still serving the old root cert from cache. Force-refresh by deleting the istiod pod; if it persists, the Helm value disabling Citadel didn't actually apply — `helm get values istiod` and verify.

### "AuthorizationPolicy denials appear after STRICT for a caller that should be allowed"

Three usual suspects: (1) the principal in the policy doesn't match the actual SPIFFE-ID on the wire — check ztunnel logs for the exact ID and compare to the policy's `from.source.principals`. Order of `ns/<ns>/sa/<sa>` matters and so does case. (2) The policy's `to` clause matches a different port than the traffic uses. (3) The policy hasn't reconciled yet — `kubectl get authorizationpolicy -n <ns> <name> -o yaml | grep generation` and confirm istiod has picked up the latest generation (Tempo span tag or ztunnel log line will reference the policy revision).

### "Browser login works but trace shows no `tls.mode=STRICT`"

Either the trace is from a connection that established BEFORE the STRICT flip (existing connections aren't forcibly re-handshaken) or the span is from a non-mesh hop. Trigger a fresh login from a private browser window after STRICT has been live for 5+ minutes.

### "The whole thing went sideways and I don't know where to start"

Run the rollback (7c.6) first. Restore PERMISSIVE, restore the AuthorizationPolicy backup. Then debug from a known-working state. The cost of rolling back and re-attempting is hours; the cost of debugging-under-broken-STRICT can be days.

### "kcadm command failed with `--otp` flag error"

You're hitting the Keycloak 26.x bug from PLAN.md's Phase 3 follow-up. This phase shouldn't need kcadm at all (no new clients), but if a kcadm operation surfaces, follow the service-account pattern in `infrastructure/keycloak/spike-token-exchange.sh` rather than user-with-TOTP auth.

---

## What's next

[Phase 7d — Rotation and housekeeping batch](./phase-07d-rotation-housekeeping.md) tackles BFF `private_key_jwt` rotation (90-day cron + runbook) and the SpiceDB `datastore_uri` static-copy → database-engine migration. 7c and 7d are independent — pick whichever is more urgent.

After 7b/7c/7d, [Phase 8 — Privileged Access (Teleport, optional)](./phase-08-teleport.md). If skipping, jump to [Phase 9](./phase-09-hello-world.md).
