# OpenBao Recovery Runbook (Local Edition)

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

> ⚠️ **Known gap on OpenBao 2.5.3 + Transit auto-unseal (local edition).** The post-Phase-7 audit observed `bao operator generate-root -init` returning `405 unsupported operation` against this configuration. The Transit-auto-unsealed branch may not expose the generate-root endpoint the way the Shamir-sealed branch does. **The [Kubernetes auth break-glass](#kubernetes-auth-break-glass) above is the canonical local-edition recovery path**; this section is retained as the cloud-edition + Shamir-sealed reference and as a fallback to attempt if the break-glass path is also unavailable. If you hit the 405, file an operator-backlog entry and prefer the rebuild path or the break-glass token.

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

The seal-OpenBao mints a periodic token (`-period=720h`, no `-ttl`/`-renewable`) bound to `unseal-policy`. **Phase 7d Item 3 update (2026-05-02; operator-backlog #4 resolved):** the prior `-ttl=24h -renewable=true` design has been replaced by a periodic token. Periodic tokens refresh their TTL on every USE, and the main OpenBao's `transit/decrypt/unseal` call at boot counts as use. So any cluster reboot within 30 days transparently extends the token's life; cold-pause must exceed 30 days continuously before the token expires. See [ADR-0009 § Known local gaps #4](../02-decisions/0009-openbao-seal-strategy.md) for the trade-off table. (Clusters bootstrapped before 2026-05-02 still hold a `-ttl=24h` token and will see the original 24h ceiling until the next `rotate-transit-token.sh` run — which mints with the new period.)

### Canonical procedure — `rotate-transit-token.sh`

```bash
bash infrastructure/openbao/rotate-transit-token.sh
```

The script prompts for the seal-OpenBao initial root token (no echo; wiped from memory after use), then runs the full sequence: refuses to start unless the seal-OpenBao is up and unsealed → mints a fresh periodic Transit token (`-period=720h` as of Phase 7d Item 3) → patches the `openbao-transit-token` Secret → runs `apply-main.sh`, which re-renders the seal block, detects the content change, force-rolls existing main pods follower-first (`openbao-2 → 1 → 0`), and blocks until all three are Ready. The watchdog inside `apply-main.sh` tracks per-pod restart-count *delta* (only restarts that happen after watch-start count against the threshold), so pre-existing crashloops from the stale token don't trigger a false-positive bail; an overall 10-minute deadline is the backstop.

If the script exits non-zero on the wait, inspect `kubectl logs -n openbao openbao-0 -c openbao --tail=30` and consult the troubleshooting section below or [§ Rebuild the seal-OpenBao](#rebuild-the-seal-openbao) if the seal-OpenBao is itself unhealthy.

### Manual procedure (reference — what the script does)

If the script is missing or you need to run the steps individually for troubleshooting:

```bash
# 1. Get a token from the seal-OpenBao using its (offline) initial root.
SEAL_ROOT=<seal-OpenBao initial root from offline storage>

NEW_TRANSIT_TOKEN=$(kubectl exec -n openbao openbao-seal-0 -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$SEAL_ROOT" \
    bao token create -policy=unseal-policy -period=720h -format=json \
    | jq -r '.auth.client_token')

# 2. Update the openbao-transit-token Secret.
kubectl -n openbao patch secret openbao-transit-token \
    --type=merge \
    -p "{\"stringData\":{\"token\":\"$NEW_TRANSIT_TOKEN\"}}"

# 3. Re-render the openbao-seal-block Secret with the new token, then
#    helm-upgrade and roll the main OpenBao pods.
bash infrastructure/openbao/apply-main.sh

# 4. (OnDelete strategy) — delete each main pod for the new seal config to load.
kubectl delete pod -n openbao openbao-2 --wait=true --timeout=60s
kubectl delete pod -n openbao openbao-1 --wait=true --timeout=60s
kubectl delete pod -n openbao openbao-0 --wait=true --timeout=60s
```

After the roll, all 3 pods auto-unseal via the new Transit token.

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
