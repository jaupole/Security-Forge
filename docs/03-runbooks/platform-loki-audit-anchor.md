# Loki log-sink audit anchor — runbook (operator-backlog #85 Phase 2 / X-R1)

Tamper-evident anchoring of the platform's **Loki** log sink — Phase 2 of #85. Phase 1
(`platform-audit-anchor-activation.md`) covers the OpenBao audit log deterministically; this
covers the *other* security-critical audit streams that flow to Loki.

## What it does

For each target namespace (`keycloak, spicedb, kyverno, spire, wazuh, cert-manager,
vault-secrets-operator, istio-ingress, istio-system, velero`), a daily CronJob anchors every
**closed 24h day-window that ended ≥ 48h ago** ("settled", so no late arrivals land in an
anchored window — Promtail's real lag is seconds): it queries Loki for `{namespace="<ns>"}`,
builds an **order-independent content set** (sort + dedup of `ts\x1flabels\x1fline`), sha256s it,
chains + Transit-signs the head (`transit/sign/audit-signing`, reused from Phase 1), and commits a
signed anchor to `jaupole/secforge-audit-anchors` under `platform/loki/<ns>/`. A daily verifier
**re-queries + re-hashes** the last 3 windows still inside the **28d horizon** (< Loki's 30d
retention) and fails the Job on any mismatch → `PlatformLokiVerifierFailing` (critical).

Per-namespace independent chains; the anchor runs in the `observability` ns (next to Loki).

## Known limitation (vs Phase 1)

Loki is **not** append-only, so this is weaker than the OpenBao Phase 1 guarantee: tampering is
detectable only for windows **still within Loki's 30d retention**, and the design assumes no log
arrives later than the 48h settle. A pathological late arrival (e.g. a multi-day Promtail backlog
replay after an outage) is now **auto-classified** as benign by the verifier (see below) rather
than failing — but if the anchor's per-entry manifest (on the `audit-loki-manifests` PVC) is lost,
the verifier fails closed on any mismatch. The crown-jewel stream (OpenBao) still has the stronger
deterministic Phase 1 anchor.

**Add/delete diffing** (false-positive suppression): each anchor also writes a per-entry sha256
manifest (gzipped) to a node-local PVC and commits its `manifest_sha256` off-node. On a `window_sha256`
mismatch the verifier verifies the manifest's hash against the committed value, then diffs the re-query:
**any anchored entry missing/modified = tamper (fail)**; **only additions = benign late-arrival drift
(a `NOTE`, job still succeeds)**. A node-root attacker who rewrites both Loki and the manifest is still
caught — the off-node `manifest_sha256` won't match. Missing/unreadable manifest ⇒ fail-closed.

## Activation (light — no STS recreate, no root token, PAT already provisioned)

The signing key, both policies, and the GitHub PAT (`secret/platform/audit-anchors-push-token`)
all already exist from Phase 1. Only a new OpenBao role + the manifests are needed.

```bash
# 0. Pull the committed change on the box.
cd ~/secforge && git pull --ff-only

# 1. Distribute the OpenBao CA to the observability ns (trust-manager Bundle now
#    selects it) so the anchor can verify openbao.openbao.svc TLS.
sudo -n kubectl apply -f ~/secforge/platform/manifests/trust-manager/01-bundles.yaml
#    confirm the ConfigMap appears (trust-manager reconciles within ~seconds):
sudo -n kubectl -n observability get configmap openbao-internal-ca-cert

# 2. Add the platform-loki-audit-signer OpenBao role (break-glass admin — same as
#    Phase 1; no 1Password root token).
SA=$(sudo -n kubectl -n openbao exec openbao-0 -c openbao -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
T=$(sudo -n kubectl -n openbao exec openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 \
      bao write -field=token auth/kubernetes/login role=admin-break-glass jwt="$SA")
printf %s "$T" | sudo -n kubectl -n openbao create secret generic openbao-root-token-tmp \
  --from-file=token=/dev/stdin
bash ~/secforge/platform/components/05j-app-vso-roles.sh   # upserts the loki-audit-signer role
sudo -n kubectl delete secret -n openbao openbao-root-token-tmp
# ⚠️ On a cluster where Phase 1 is ALREADY live: 05j re-applies the openbao 12/13
#    manifests, which ship suspend:true → it RE-SUSPENDS the Phase 1 openbao
#    cronjobs. Either (a) re-unsuspend them after (kubectl -n openbao patch cronjob
#    platform-audit-anchor/-verifier -p '{"spec":{"suspend":false}}'), or (b) skip
#    05j and create just the new role directly via break-glass:
#      kubectl -n openbao exec openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN=$T \
#        bao write auth/kubernetes/role/platform-loki-audit-signer \
#        bound_service_account_names=platform-loki-audit-signer \
#        bound_service_account_namespaces=observability \
#        audience=https://kubernetes.default.svc.cluster.local \
#        token_policies=audit-signer,platform-audit token_ttl=900 token_max_ttl=1800 \
#        alias_name_source=serviceaccount_uid
# Apply the Loki anchor + verifier manifests (05j does NOT — it owns the openbao
# 12/13; 07f-loki.sh owns 21/22 on a fresh build):
cd ~/secforge/platform && lib/apply-manifest.sh \
  manifests/observability/21-loki-audit-anchor.yaml \
  manifests/observability/22-loki-audit-verifier.yaml

# 3. Confirm the PAT secret rendered in observability (force-sync if needed):
sudo -n kubectl -n observability get secret audit-anchors-push-token || \
  sudo -n kubectl -n observability annotate vaultstaticsecret audit-anchors-push-token \
    vso.hashicorp.com/force-sync="$(date +%s)" --overwrite

# 4. Unsuspend the CronJobs (do this LAST — re-applying the manifests re-suspends them).
sudo -n kubectl -n observability patch cronjob platform-loki-audit-anchor   -p '{"spec":{"suspend":false}}'
sudo -n kubectl -n observability patch cronjob platform-loki-audit-verifier -p '{"spec":{"suspend":false}}'
```

> `05j` also applies `21-`/`22-`; on a fresh build `07f-loki.sh` does the apply instead.

## Verify end-to-end

```bash
# 1. Anchor test — commits one settled window per namespace to platform/loki/<ns>/<date>.json.
sudo -n kubectl -n observability create job --from=cronjob/platform-loki-audit-anchor loki-anchor-test
sudo -n kubectl -n observability logs job/loki-anchor-test -f
#   expect e.g.: "keycloak: anchored window 2026-06-06 [N entries, B bytes] -> platform/loki/keycloak/2026-06-06.json"

# 2. Confirm the commits (public repo): github.com/jaupole/secforge-audit-anchors/tree/main/platform/loki

# 3. Verifier on the clean chain → exit 0.
sudo -n kubectl -n observability create job --from=cronjob/platform-loki-audit-verifier loki-verify-test
sudo -n kubectl -n observability logs job/loki-verify-test
#   expect: "platform-loki-audit: all namespace chains intact."

# 4. Determinism: re-run the anchor for the same settled window → identical window_sha256
#    (no new commit; "up to date — skip"). Proves the content-set hash is query-stable.

# 5. Clean up.
sudo -n kubectl -n observability delete job loki-anchor-test loki-verify-test
```

## Operations

The verifier now **auto-classifies** add-drift vs tamper (see "Add/delete diffing" above), so a
failure is real. Inspect: `kubectl -n observability logs job/<latest platform-loki-audit-verifier job>`
- `TAMPER: <ns> window <date> — N anchored entries MISSING/modified` → a still-in-retention Loki
  window had entries removed/changed vs its signed manifest → treat as an active node compromise
  (X-R1/P1), logs rewritten in MinIO.
- `TAMPER: <ns> per-entry manifest <date> hash != committed` → the local manifest PVC was tampered
  (off-node `manifest_sha256` caught it) → same compromise signal.
- `TAMPER: <ns> window <date> ... no per-entry manifest to classify` → fail-closed because the
  manifest is missing (e.g. PVC lost on a rebuild, or window older than `MANIFEST_RETENTION_DAYS`).
  Re-baseline that ns if the drift is benign: delete `platform/loki/<ns>/_state.json` (prior anchors
  stay as the immutable signed record).
- A `NOTE: ... drifted +N entries (benign late arrivals, 0 deletions)` is **not** a failure — the
  job still succeeds; it just records that the window grew after settling.
- Any other non-zero exit is operational (Loki or raw.githubusercontent unreachable) — transient.

**Tuning** (CronJob env): `SETTLE_SECONDS` (default 172800/48h — raise if late arrivals recur),
`VERIFY_WINDOWS` (default 3 — windows re-queried per run), `VERIFY_HORIZON_SECONDS` (default
2419200/28d — keep < Loki retention), `LOKI_NAMESPACES` (the anchored set).

**Adding a namespace:** append it to `LOKI_NAMESPACES` on both CronJobs (21-/22-); its chain
starts at the next anchor run (genesis = the latest settled day, no backfill).

## Future hardening

- **Per-entry add/delete diffing — ✅ BUILT 2026-06-08** (the `audit-loki-manifests` PVC +
  `manifest_sha256`); the verifier auto-classifies drift vs tamper.
- **MinIO object-lock/WORM on `loki-chunks` — deliberately deferred.** Object-lock is create-time-only
  (would require recreating the bucket + a Loki storage migration) and conflicts with Loki retention;
  and against the X-R1 actor (node-root) it's only marginal defence-in-depth (node-root can bypass
  MinIO enforcement at the host — SSE-S3 + the off-node anchor are the real defences). Revisit only if
  a MinIO-credential-only threat (not host-root) becomes load-bearing. See operator-backlog #85.

## References

- `platform/manifests/observability/21-loki-audit-anchor.yaml` / `22-loki-audit-verifier.yaml`
- `platform/components/05j-app-vso-roles.sh` (role) · `07f-loki.sh` (apply)
- `platform/manifests/trust-manager/01-bundles.yaml` (OpenBao CA → observability)
- `platform/manifests/observability/09-platform-alerts.yaml` (`platform-loki-audit-anchoring`)
- `docs/03-runbooks/platform-audit-anchor-activation.md` (Phase 1 sibling)
- `docs/04-security/threat-model.md` §0.5 (X-R1)
- <https://github.com/jaupole/secforge-audit-anchors>
