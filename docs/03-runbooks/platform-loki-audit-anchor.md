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
replay after an outage) can cause a benign verifier failure — classify it (see Operations). The
crown-jewel stream (OpenBao) already has the stronger deterministic Phase 1 anchor.

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
bash ~/secforge/platform/components/05j-app-vso-roles.sh   # upserts the role + applies 21/22
sudo -n kubectl delete secret -n openbao openbao-root-token-tmp

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

**Classifying a verifier failure** (`PlatformLokiVerifierFailing`):
`kubectl -n observability logs job/<latest platform-loki-audit-verifier job>`
- `TAMPER: <ns> window <date> content changed` → a still-in-retention Loki window no longer
  matches its signed anchor. Compare the committed `window_sha256`/`entry_count` against a fresh
  query of that ns + window. If entries are **missing or modified**, treat as an active node
  compromise (X-R1/P1) — logs were rewritten in MinIO. If the re-query is a strict **superset**
  (only additions), it's a benign late-arrival drift: re-baseline that ns by deleting
  `platform/loki/<ns>/_state.json` (the prior anchors stay as the immutable signed record).
- Any other non-zero exit is operational (Loki or raw.githubusercontent unreachable) — transient,
  next run self-heals.

**Tuning** (CronJob env): `SETTLE_SECONDS` (default 172800/48h — raise if late arrivals recur),
`VERIFY_WINDOWS` (default 3 — windows re-queried per run), `VERIFY_HORIZON_SECONDS` (default
2419200/28d — keep < Loki retention), `LOKI_NAMESPACES` (the anchored set).

**Adding a namespace:** append it to `LOKI_NAMESPACES` on both CronJobs (21-/22-); its chain
starts at the next anchor run (genesis = the latest settled day, no backfill).

## Future hardening (follow-up, not built)

- MinIO **object-lock/WORM** on the `loki-chunks` bucket (TTL-aligned to retention) would make the
  underlying chunks immutable at the storage layer — stronger than re-query detection.
- Committing a per-entry hash set (to MinIO) would let the verifier diff additions vs
  deletions/modifications automatically, removing the late-arrival false-positive.

## References

- `platform/manifests/observability/21-loki-audit-anchor.yaml` / `22-loki-audit-verifier.yaml`
- `platform/components/05j-app-vso-roles.sh` (role) · `07f-loki.sh` (apply)
- `platform/manifests/trust-manager/01-bundles.yaml` (OpenBao CA → observability)
- `platform/manifests/observability/09-platform-alerts.yaml` (`platform-loki-audit-anchoring`)
- `docs/03-runbooks/platform-audit-anchor-activation.md` (Phase 1 sibling)
- `docs/04-security/threat-model.md` §0.5 (X-R1)
- <https://github.com/jaupole/secforge-audit-anchors>
