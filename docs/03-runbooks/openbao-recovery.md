# OpenBao Recovery Runbook

> **Production note.** Written for the local edition. In production: OpenBao is 2.5.4 (3 nodes + 1 seal node, Transit auto-unseal); a "Docker Desktop restart" maps to a **node reboot** (after a power-cycle the seal needs unsealing); OpenBao is reached at **`bao.secforge.dev` (tailnet-only)**; the cluster is **Hetzner k3s**. Verify steps against the live cluster before acting. See [PLAN.md](../../PLAN.md).

> Architecture: [docs/01-architecture/05-secrets-management.md](../01-architecture/05-secrets-management.md)
> ADR: [docs/02-decisions/0009-openbao-seal-strategy.md](../02-decisions/0009-openbao-seal-strategy.md)
> Companion: [openbao-seal-unseal.md](./openbao-seal-unseal.md) (routine post-restart unsealing)

Break-glass procedures for OpenBao when normal admin paths are broken.

---

## Decision tree

| Symptom | Procedure |
|---|---|
| You lost / revoked the OpenBao admin token AND OIDC login is broken | [Generate a new root token](#generate-a-new-root-token-via-recovery-keys) |
| Both OpenBao instances came up sealed after a restart | [openbao-seal-unseal.md](./openbao-seal-unseal.md) |
| Main OpenBao won't auto-unseal even though seal-OpenBao is unsealed | [Rotate the Transit unseal token](#rotate-the-transit-unseal-token) |
| You suspect the seal-OpenBao is compromised | [Rebuild the seal-OpenBao](#rebuild-the-seal-openbao) (destructive) |
| You lost the seal-OpenBao unseal keys | [openbao-seal-unseal.md "What the unseal keys are"](./openbao-seal-unseal.md#what-the-unseal-keys-are) (start over) |
| You need admin from inside the cluster but OIDC's broken | [Use the kubernetes break-glass role](#kubernetes-auth-break-glass) |

---

## Kubernetes auth break-glass

Phase 5.6 staged a `kubernetes/role/admin-break-glass` bound to the `openbao` ServiceAccount with the `admin` policy and a 1h TTL. It's the fastest in-cluster admin recovery path.

```bash
SA_JWT=$(kubectl exec -n openbao openbao-0 -- \
    cat /var/run/secrets/kubernetes.io/serviceaccount/token)

ADMIN_TOKEN=$(kubectl exec -n openbao openbao-0 -c openbao -- \
    env BAO_SKIP_VERIFY=1 \
    bao write -format=json auth/kubernetes/login \
        role=admin-break-glass jwt="$SA_JWT" \
    | jq -r '.auth.client_token')

kubectl exec -n openbao openbao-0 -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ADMIN_TOKEN" bao token lookup
```

The token expires in 1h, can't be renewed past `max_ttl=1h`. Use it to fix what's broken (re-enable OIDC, rotate a credential, etc.) and let it expire.

**Why this isn't a long-lived admin path:** the `openbao` ServiceAccount lives in the openbao namespace; anyone with `kubectl exec` into that ns can mint this token. Cluster-admin RBAC is the boundary. For local edition that's appropriate; cloud edition replaces this with a tighter audited path (e.g., GitHub Actions OIDC with workload identity).

---

## Generate a new root token via recovery keys

> ⚠️ **Known gap on OpenBao 2.5.3 — `generate-root` returns 405 on BOTH instances.** The post-Phase-7 audit originally observed `bao operator generate-root -init` returning `405 unsupported operation` against transit-auto-unsealed main OpenBao. The 2026-05-28 seal-token rotation session **re-confirmed the same 405 against the shamir-sealed openbao-seal instance** — generate-root is structurally unsupported on this OpenBao build, not just on the transit-auto-unsealed branch. **The [Kubernetes auth break-glass](#kubernetes-auth-break-glass) above is the canonical recovery path for MAIN OpenBao**; for openbao-seal there is **no equivalent break-glass today** (see operator-backlog #69). Until #69 lands, openbao-seal admin recovery depends on the operator-stored initial root token. If both that token AND a viable Velero backup are missing, the recovery path is destructive rebuild ([§ Rebuild the seal-OpenBao](#rebuild-the-seal-openbao)).
>
> The recovery-key generate-root procedure below is retained for the cloud-edition / future-OpenBao-version reference. If you hit the 405 on this build, jump directly to the break-glass on main OpenBao or — for openbao-seal — to the offline root or rebuild.

Use this when the OpenBao initial root has been revoked AND your OIDC admin path is also broken (so you can't get *any* admin via the normal flows). You'll need 3 of the 5 **recovery keys** stored offline at Phase 5.3 Checkpoint 2.

Recovery keys are NOT unseal keys; they only let you mint a new root token on an *already-unsealed* OpenBao. The main OpenBao must be unsealed (which the auto-unseal flow handles).

```bash
# Step 1: initiate generate-root. Returns OTP + nonce. The OTP is what
# decodes the encoded token in step 3.
kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 \
    bao operator generate-root -init
# Save the printed Nonce and OTP.

# Step 2: feed 3 of 5 recovery keys against the nonce, one at a time.
for KEY in "<recovery-key-1>" "<recovery-key-2>" "<recovery-key-3>"; do
    kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 \
        bao operator generate-root -nonce=<nonce-from-step-1> "$KEY"
done
# After the 3rd key, the response includes "Encoded Token: ...".

# Step 3: decode with the OTP.
kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 \
    bao operator generate-root \
    -decode=<encoded-token-from-step-2> \
    -otp=<otp-from-step-1>
# Output is a fresh root token (s.XXX...). Save it offline immediately.
```

The new root is **equivalent** to the original — same powers, no expiry. Revoke any prior tokens with `bao token revoke s.XXX`.

Best practice: use this root only to fix the broken admin path, then revoke it the same way you revoked the initial root in Phase 5.6.

---

## Rotate the Transit unseal token

The seal-OpenBao mints a periodic token (`-period=720h`, no `-ttl`/`-renewable`) bound to `unseal-policy`. **Phase 7d Item 3 update (2026-05-02; operator-backlog #4 resolved):** the prior `-ttl=24h -renewable=true` design has been replaced by a periodic token. Periodic tokens refresh their TTL on every USE, and the main OpenBao's `transit/decrypt/unseal` call at boot counts as use. So any cluster reboot within 30 days transparently extends the token's life; cold-pause must exceed 30 days continuously before the token expires. See [ADR-0009 § Known local gaps #4](../02-decisions/0009-openbao-seal-strategy.md) for the trade-off table.

> **2026-05-28 architecture note:** the seal config now lives in K8s Secret `openbao-seal-block` (the full `seal.hcl` content, including the token), mounted at `/openbao/userconfig/seal-block/openbao-seal-block/seal.hcl` on each main OpenBao pod. The older local-edition pattern with a separate `openbao-transit-token` Secret + `apply-main.sh` rendering job has been retired with the rest of the `infrastructure/` tree. The procedure below reflects the **current** platform-tree shape.

### Procedure (verified 2026-05-28)

You need the **seal-OpenBao** initial root token from offline storage (admin-break-glass exists only on main OpenBao — see operator-backlog #69 for the seal-side gap).

```bash
SEAL_ROOT=<seal-OpenBao initial root from offline storage>

# 1. Validate the root token works on openbao-seal
kubectl -n openbao exec openbao-seal-0 -c openbao -- \
    env BAO_ADDR=https://localhost:8200 BAO_SKIP_VERIFY=1 BAO_TOKEN="$SEAL_ROOT" \
    bao token lookup
# Should show policies=[root], expire_time=<nil>. If 403, the token has been revoked
# — fall through to § Rebuild the seal-OpenBao or hunt for the right offline copy.

# 2. Mint a new periodic transit token bound to unseal-policy
NEW_TOKEN=$(kubectl -n openbao exec openbao-seal-0 -c openbao -- \
    env BAO_ADDR=https://localhost:8200 BAO_SKIP_VERIFY=1 BAO_TOKEN="$SEAL_ROOT" \
    bao token create -policy=unseal-policy -period=720h -format=json \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["auth"]["client_token"])')

# 3. Verify the new token has transit/decrypt + transit/encrypt on the unseal key
for cap in transit/decrypt/unseal transit/encrypt/unseal; do
  kubectl -n openbao exec openbao-seal-0 -c openbao -- \
      env BAO_ADDR=https://localhost:8200 BAO_SKIP_VERIFY=1 BAO_TOKEN="$NEW_TOKEN" \
      bao token capabilities "$cap"
  # Each should print: update
done

# 4. Backup the current openbao-seal-block Secret before mutation
kubectl -n openbao get secret openbao-seal-block -o yaml \
    > /tmp/openbao-seal-block.backup.$(date +%Y%m%d-%H%M%S).yaml

# 5. Extract the current seal.hcl, swap the token line, patch the Secret
OLD_TOKEN=$(kubectl -n openbao get secret openbao-seal-block \
    -o jsonpath='{.data.seal\.hcl}' | base64 -d | grep -oP '"\Ks\.[A-Za-z0-9]+(?=")')
kubectl -n openbao get secret openbao-seal-block \
    -o jsonpath='{.data.seal\.hcl}' | base64 -d \
    | sed "s|$OLD_TOKEN|$NEW_TOKEN|" \
    > /tmp/seal.hcl.new
NEW_B64=$(base64 -w0 /tmp/seal.hcl.new)
kubectl -n openbao patch secret openbao-seal-block --type=merge \
    -p "{\"data\":{\"seal.hcl\":\"$NEW_B64\"}}"
rm -f /tmp/seal.hcl.new

# 6. Identify the leader pod (restart followers first, leader last)
for p in openbao-0 openbao-1 openbao-2; do
  ROLE=$(kubectl -n openbao exec $p -c openbao -- \
      env BAO_ADDR=https://localhost:8200 BAO_SKIP_VERIFY=1 \
      bao status -format=json \
      | python3 -c 'import json,sys;print("leader" if json.load(sys.stdin).get("is_self") else "follower")')
  echo "$p: $ROLE"
done

# 7. Restart each pod (followers first, leader last). Wait for Ready + unsealed
#    after each before continuing — raft tolerates 1/3 down; do not parallelize.
for pod in <follower-1> <follower-2> <leader>; do
  kubectl -n openbao delete pod $pod
  for i in $(seq 1 20); do
    READY=$(kubectl -n openbao get pod $pod -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "?")
    [ "$READY" = "true" ] && break
    sleep 5
  done
  kubectl -n openbao exec $pod -c openbao -- \
      env BAO_ADDR=https://localhost:8200 BAO_SKIP_VERIFY=1 \
      bao status | grep -E '(Initialized|Sealed)'
  # Both should show: Initialized=true, Sealed=false
done

# 8. Revoke the old periodic token (closes any state.db kine MVCC exposure)
kubectl -n openbao exec openbao-seal-0 -c openbao -- \
    env BAO_ADDR=https://localhost:8200 BAO_SKIP_VERIFY=1 BAO_TOKEN="$SEAL_ROOT" \
    bao token revoke "$OLD_TOKEN"

# 9. Sanity-check: an app-side VSS is still SYNCED (proves main OpenBao + VSO chain healthy)
kubectl -n control get vaultstaticsecret control-app-secrets
```

After step 7, all 3 pods are using the new transit token. The OLD token is dead after step 8.

### Gotchas surfaced during the 2026-05-28 rotation

- **The seal config Secret is `openbao-seal-block`, NOT `openbao-transit-token`.** Older runbook references to `openbao-transit-token` reflect the retired local-edition pattern.
- **Don't use `bao login`** with the seal root; use `BAO_TOKEN=` env var only. `bao login` enables the dangerous `bao token revoke -self` codepath (see [[feedback_no_bao_token_revoke_self]] in operator memory).
- **`generate-root` returns 405 on openbao-seal too** (not just main openbao). The recovery-keys-based generate-root path is structurally broken on OpenBao 2.5.3 across both instances.
- **The seal-OpenBao has no k8s-auth break-glass role today** (operator-backlog #69). If the offline seal root is lost AND `generate-root` is broken, the only recovery path is destructive rebuild.

### Codified-script gap

A `rotate-transit-token.sh` script under `platform/components/` would make this procedure idempotent + safer (avoid the manual sed step in #5, the manual leader-identification in #6). Tracked at operator-backlog #71 (filed alongside the 2026-05-28 rotation execution). Until that lands, the manual procedure above is the canonical reference.

---

## Rebuild the seal-OpenBao

⚠️ **Destructive**. The main OpenBao's data store is encrypted with a key wrapped by the seal-OpenBao's Transit endpoint. Rebuilding the seal-OpenBao means the main OpenBao can't decrypt its data. Both must be rebuilt together.

When you'd do this:
- Suspected compromise of the seal-OpenBao (its root token leaked, its PVC was copied off-cluster, etc.)
- The seal-OpenBao's PVC corrupted

Procedure:

```bash
# 1. Collect what you can from the running OpenBao via the admin API
#    (KV secrets, policy definitions). After rebuild you'll restore these.

# 2. Tear down both OpenBaos and their PVCs.
helm uninstall openbao openbao-seal -n openbao
kubectl delete pvc -n openbao -l app.kubernetes.io/name=openbao
kubectl delete pvc -n openbao -l app.kubernetes.io/name=openbao-seal
kubectl -n openbao delete secret openbao-transit-token openbao-seal-block

# 3. Re-bootstrap (Phase 5.2 + 5.3).
bash infrastructure/openbao/apply-seal.sh
bash infrastructure/openbao/init-seal.sh
# Save the new Phase 5.2 secrets offline (5 unseal keys, root, Transit token).

# Update the openbao-transit-token Secret with the new Transit token.
kubectl -n openbao create secret generic openbao-transit-token \
    --from-literal=token=<new-Transit-token>

bash infrastructure/openbao/apply-main.sh
bash infrastructure/openbao/init-main.sh
# Save the new Phase 5.3 secrets offline (5 recovery keys, root).

# 4. Re-apply the operational config.
BAO_TOKEN=<new-main-root> bash infrastructure/openbao/configure-engines.sh
BAO_TOKEN=<new-main-root> bash infrastructure/openbao/load-policies.sh
BAO_TOKEN=<new-main-root> bash infrastructure/openbao/configure-auth-k8s-jwt.sh

# OIDC: re-create the openbao Keycloak client OR reuse the existing one.
# If reusing, fetch the existing client_secret from Keycloak admin UI.
BAO_TOKEN=<new-main-root> CLIENT_SECRET=<from-Keycloak> \
    bash infrastructure/openbao/configure-auth-oidc.sh

# 5. Restore secrets from your pre-rebuild dump.
bash infrastructure/openbao/migrate-secrets.sh   # re-pulls from K8s Secrets

# 6. Revoke the new initial root once OIDC is verified working.
kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 \
    BAO_TOKEN=<new-main-root> bao token revoke <new-main-root>
```

This is "start over" — be sure it's needed before doing it.

---

## Daily backup of seal-OpenBao state

The seal-OpenBao is the trusted root; its loss cascades to total OpenBao data loss. A simple daily snapshot:

```bash
# Backup the seal-OpenBao's PVC (data + transit key wrap).
kubectl exec -n openbao openbao-seal-0 -c openbao -- \
    tar -cf - /openbao/data | gzip -9 \
    > /backup/openbao-seal-$(date +%Y%m%d).tar.gz
```

Restore by reverse-piping into a fresh seal-OpenBao before initialization:

```bash
gunzip < /backup/openbao-seal-DATE.tar.gz | \
    kubectl exec -i -n openbao openbao-seal-0 -c openbao -- \
    tar -xf - -C /
# Then unseal with the original keys (since the data IS the original).
```

For local edition this is optional — your unseal keys + Transit token can rebuild from scratch — but the snapshot saves the fresh-restart-of-everything cost.

---

## Restore Prometheus metrics-scrape auth

**Symptom:** Wazuh dashboard noise of rule `100001` (chart catch-all "Application error detected" at level 10) firing every ~30s with `data.request.path=sys/metrics`, `operation=read`, `error="permission denied"`. Source IP is the `prometheus-kps-prometheus-0` pod. Grafana OpenBao panels (Raft state, lease counters, unseal status) go empty. Consistent with backlog item #26 (closed 2026-05-05).

**Root cause class — periodic-token renew-on-USE pattern can lock out:** Phase 7d Item 4 mints a `period=720h` token bound to `metrics-policy` and writes it to K8s Secret `openbao/openbao-metrics-token`. Periodic tokens auto-refresh their TTL on every successful USE — but if scrapes start failing (network blip, OpenBao restart causing TLS handshake mismatch, NetworkPolicy drift, listener flip), USE doesn't happen, the period decrements untouched, and once it ages out the token is dead. Prometheus keeps re-presenting the same dead token, every denial generates an audit event, and the Wazuh ingest pipeline amplifies the spam.

**Why `bao token lookup-self` against the metrics token is NOT a useful liveness check:** the metrics token is minted with `-no-default-policy`, so it can't read `auth/token/lookup-self` even when fresh. Always lookup-by-id from an admin token's perspective:

```bash
NEW_TOKEN=$(kubectl get secret -n openbao openbao-metrics-token -o jsonpath='{.data.token}' | base64 -d)
kubectl exec -n openbao openbao-0 -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao token lookup "$NEW_TOKEN"
```

**Recovery — re-run the bootstrap script (idempotent):**

```bash
# 1. Get an admin token (interactive OIDC + TOTP).
kubectl port-forward -n openbao svc/openbao 8200:8200 &
BAO_SKIP_VERIFY=1 BAO_ADDR=https://127.0.0.1:8200 \
    bao login -method=oidc role=admin

# 2. Re-mint the metrics token + overwrite the K8s Secret.
BAO_TOKEN=$(bao print token) \
    bash infrastructure/openbao/configure-metrics-auth.sh
```

The script rotates the metrics token, rewrites the Secret, and the Prometheus pod picks up the new token from its mounted-Secret file on its next scrape (~30-60s) without a restart — kubelet auto-reconciles the projected Secret and Prometheus reads the bearer token file per scrape.

**Verify:**

```bash
# (a) audit log shows successful scrapes (error: null on response events)
kubectl logs -n openbao openbao-0 -c openbao --tail=50 \
    | grep '"path":"sys/metrics"' | tail -4

# (b) Prometheus has openbao metrics
kubectl port-forward -n observability svc/kps-prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/query?query=vault_core_unsealed' | jq

# (c) Wazuh stops generating data.error events on sys/metrics
WPW=$(kubectl get secret -n wazuh wazuh-indexer-creds -o jsonpath='{.data.password}' | base64 -d)
TS=$(date -u -d '120 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
kubectl exec -n wazuh wazuh-indexer-0 -- curl -sk -u "admin:$WPW" \
    -H 'Content-Type: application/json' \
    "https://localhost:9200/wazuh-alerts-4.x-*/_search?size=0" \
    -d "{\"query\":{\"bool\":{\"must\":[{\"range\":{\"@timestamp\":{\"gte\":\"$TS\"}}},{\"match_phrase\":{\"data.request.path\":\"sys/metrics\"}},{\"exists\":{\"field\":\"data.error\"}}]}},\"track_total_hits\":true}" \
    | jq '.hits.total'
# Expected: total.value = 0
```

**If the policy itself is missing or detached** (rarer than token expiry — confirm with `bao policy read metrics-policy` and `bao token lookup <token>`'s `policies` field), the same script reloads the policy idempotently.

**If the ServiceMonitor wiring drifts** (gotcha: `bearerTokenSecret` is resolved by Prometheus Operator in the SAME namespace as the ServiceMonitor, NOT the Prometheus pod's namespace — the metrics-token Secret MUST live in `openbao` ns, not `observability`), inspect `kubectl get servicemonitor -n openbao openbao -o yaml` and re-apply `infrastructure/openbao/09-servicemonitor.yaml`.
