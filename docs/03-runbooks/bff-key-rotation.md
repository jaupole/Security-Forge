# BFF `private_key_jwt` rotation

> **Scope:** the four BFF clients in the `secforge-tenants` Keycloak realm — `helloworld-bff`, `proposal-forge-bff`, `project-tracker-bff`, `pm-bff`. Each holds an RSA-2048 keypair used for `private_key_jwt` client authentication (PS256). Phase 6.10b moved the keys into OpenBao at `secret/data/keycloak/clients/<id>`; Phase 7d.1 added rotation tooling.
>
> **Cadence:** 90 days, automated via four staggered CronJobs (`bff-key-rotator-<bff>` in `app` ns). Manual rotation is supported for ad-hoc events (suspected compromise, off-cycle rollover).

---

## How rotation works (single-key atomic swap)

The current Keycloak client config registers the public key via the single-value attribute `jwt.credential.public.key`. Multi-key JWKS overlap is **not** in use, so rotation is an atomic swap, not a parallel-keys roll. The trade-off is brief BFF unavailability between the Keycloak-side update and the BFF pod restart completing.

The script `infrastructure/keycloak/realms/rotate-bff-key.sh` performs:

1. **Generate** a fresh RSA-2048 keypair locally (`openssl genrsa`).
2. **Pre-flight** checks: target client exists in Keycloak, OpenBao path readable, BFF Deployment exists.
3. **Write** new `private_pem`+`public_pem` as a new KV-v2 version at `secret/data/keycloak/clients/<id>`.
4. **Update Keycloak** — read current client JSON, set `attributes."jwt.credential.public.key"` to the new bare-base64 PEM body, PUT back. All other attributes (DPoP, PKCE, PAR, PS256, …) are preserved.
5. **Rolling-restart** the BFF Deployment in `app` ns.
6. **Wait** for rollout to complete (180s timeout). Failure = exit non-zero.

After step 4, assertions signed with the **old** private key are rejected. The window of unavailability is the time between step 4 and the new BFF pod becoming `Ready` again — typically 10–30s on local edition. Plan rotations during low-traffic windows; the cron schedule (02:00 UTC) is set with this in mind.

---

## Manual rotation (host-side)

Use this for ad-hoc rotation, suspected compromise, or to verify the procedure end-to-end before relying on the cron.

**Prerequisites:**

- `BAO_TOKEN` exported in your shell with the capabilities listed in [`infrastructure/openbao/policies/bff-key-rotator.hcl`](../../infrastructure/openbao/policies/bff-key-rotator.hcl) (or admin-tier, e.g., from `bao login -method=oidc role=admin`).
- The target BFF Deployment is up and `Ready` in `app` ns.

**Run:**

```bash
BAO_TOKEN=hvs.xxx bash infrastructure/keycloak/realms/rotate-bff-key.sh helloworld-bff
```

Output is one structured-JSON line per step (`event=bff.key.rotation.step` for progress, `event=bff.key.rotation.success` on success, `event=bff.key.rotation.failed` on failure). Promtail picks these up via the standard pod-log scrape if you redirect to a pod (cron path); host-side runs go to your terminal.

**Verify success:**

1. New KV-v2 version recorded:
   ```bash
   kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN=$BAO_TOKEN \
     bao kv metadata get -mount=secret keycloak/clients/helloworld-bff
   ```
   `current_version` should equal the previous + 1.

2. New public key on the Keycloak client:
   ```bash
   kubectl exec -n keycloak keycloak-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh \
     get clients -r secforge-tenants -q clientId=helloworld-bff \
     --fields 'attributes(jwt.credential.public.key)'
   ```
   The base64 body should match the new `public_pem` in OpenBao (sans `-----BEGIN/END-----` and newlines).

3. **Fresh end-to-end login** (the high-confidence test):
   ```bash
   curl -fsS https://app.secforge.local/healthz   # should be 200
   ```
   Then perform a real login at `https://app.secforge.local/login` and confirm the redirect chain through Keycloak completes. The BFF logs (Loki) will show `oidc client ready` with the new `kid`.

4. The new `kid` appears in Keycloak event logs for `client_assertion` validation:
   ```
   {namespace="keycloak", app="keycloak"} |= "client_assertion" |= "<new_kid>"
   ```
   in Grafana / Loki. (The BFF computes `kid = base64url(SHA-256(DER-PKIX(pub)))` — Keycloak-shaped — so both sides agree without explicit `kid` plumbing.)

---

## Cron-driven rotation

**Where the CronJobs live:** `app` namespace, name pattern `bff-key-rotator-<bff>`.

**Schedule (staggered across each 90-day window):**

| Client | Cron expression | Approx day-of-window | Status today |
|---|---|---|---|
| `helloworld-bff` | `0 2 1 1,4,7,10 *` (1st of Jan/Apr/Jul/Oct, 02:00 UTC) | 0 | **enabled** (suspend:false) |
| `proposal-forge-bff` | `0 2 23 1,4,7,10 *` (23rd of same months) | ~22 | suspend:true (BFF not deployed) |
| `project-tracker-bff` | `0 2 15 2,5,8,11 *` (15th of Feb/May/Aug/Nov) | ~45 | suspend:true (BFF not deployed) |
| `pm-bff` | `0 2 7 3,6,9,12 *` (7th of Mar/Jun/Sep/Dec) | ~67 | suspend:true (BFF not deployed) |

**Unsuspend a placeholder when its BFF lands** (Phase 9+ for helloworld; Phase 10+ for the others):

```bash
kubectl patch cronjob -n app bff-key-rotator-proposal-forge-bff \
    --type=merge -p '{"spec":{"suspend":false}}'
```

**Trigger a one-off rotation immediately** (e.g., to verify the cron path produces the same result as the manual path):

```bash
kubectl create job -n app bff-key-rotator-manual-$(date +%s) \
    --from=cronjob/bff-key-rotator-helloworld-bff
```

**How the cron pod authenticates:**

1. The `spiffe-helper` init container writes a JWT-SVID (audience=`openbao`) to `/shared/openbao.jwt`.
2. `wrapper.sh` POSTs the JWT to OpenBao `auth/jwt/login` (role `bff-key-rotator`), captures `client_token` as `BAO_TOKEN`.
3. `wrapper.sh` execs `rotate-bff-key.sh`. The script's `_lib/kcadm-auth.sh` helper (mounted into `/scripts/kcadm-auth.sh`, override via `KCADM_AUTH_HELPER` env) reads kcadm-admin's client_secret from `secret/data/keycloak/clients/kcadm-admin` and authenticates `kcadm.sh` against the master realm.
4. The OpenBao policy `bff-key-rotator` ([source](../../infrastructure/openbao/policies/bff-key-rotator.hcl)) allows: read on the kcadm-admin path, read/create/update on each `secret/data/keycloak/clients/<bff>` path.

The cron pod has the K8s RBAC required to (a) `pods/exec` on `openbao-0` and `keycloak-0` (specific pods, scoped via `resourceNames`), (b) `patch` and `get/list/watch` on the four BFF `Deployments`, (c) `get/list/watch` on `replicasets` and `pods` in `app` ns (for `kubectl rollout status`).

---

## Auth path question (kcadm-admin migration state)

**Today (2026-05-02): kcadm-admin migration is COMPLETE** (per [ADR-0022](../02-decisions/0022-kcadm-admin-long-lived-credential.md), commit `phase-3-fu (3/4)`). Both the manual and cron paths use `kcadm-admin` as the master-realm service-account client. The script sources `infrastructure/keycloak/_lib/kcadm-auth.sh` which fetches kcadm-admin's `client_secret` from OpenBao and authenticates `kcadm.sh` via `--client kcadm-admin --secret <fetched>`.

If the kcadm-admin client itself needs rotation, see [`docs/03-runbooks/keycloak-operations.md`](./keycloak-operations.md) — that's a separate procedure from BFF key rotation.

---

## Rollback

If a rotation breaks login (the BFF can't reach the token endpoint, or `client_assertion` is rejected), restore the previous KV-v2 version and re-register the corresponding public key with Keycloak:

```bash
# 1. Identify the previous KV-v2 version.
kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN=$BAO_TOKEN \
    bao kv metadata get -mount=secret keycloak/clients/helloworld-bff
# Note current_version=N; you want to roll back to N-1.

# 2. Read the previous version's public_pem.
kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN=$BAO_TOKEN \
    bao kv get -mount=secret -version=$((N-1)) -field=public_pem keycloak/clients/helloworld-bff > /tmp/prev-pub.pem

# 3. Read the previous version's private_pem and write it to the latest version
#    so the BFF picks it up on restart.
PREV_PRIV=$(kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN=$BAO_TOKEN \
    bao kv get -mount=secret -version=$((N-1)) -field=private_pem keycloak/clients/helloworld-bff)
PREV_PUB=$(cat /tmp/prev-pub.pem)
JSON=$(jq -n --arg p "$PREV_PRIV" --arg q "$PREV_PUB" --arg c helloworld-bff --arg s "rollback-from-N-1-$(date -u +%FT%TZ)" \
    '{private_pem:$p, public_pem:$q, client_id:$c, source:$s}')
kubectl exec -i -n openbao openbao-0 -c openbao -- sh -c 'cat > /tmp/rollback.json' <<<"$JSON"
kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN=$BAO_TOKEN \
    bao kv put -mount=secret keycloak/clients/helloworld-bff @/tmp/rollback.json
kubectl exec -n openbao openbao-0 -c openbao -- rm -f /tmp/rollback.json

# 4. Push the matching public key back to Keycloak (use the same edit-then-PUT
#    pattern the rotation script uses, but with the OLD public-key value).
PUB_BARE=$(printf '%s' "$PREV_PUB" | sed -e '/^-----BEGIN/d' -e '/^-----END/d' | tr -d '\n')
. infrastructure/keycloak/_lib/kcadm-auth.sh
kcadm_admin_auth
KC_INT_ID=$(kubectl exec -n keycloak keycloak-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh \
    get clients -r secforge-tenants -q clientId=helloworld-bff --fields id --format csv --noquotes | tr -d '\r' | head -1)
CLIENT_JSON=$(kubectl exec -n keycloak keycloak-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh \
    get clients/$KC_INT_ID -r secforge-tenants | tr -d '\r')
echo "$CLIENT_JSON" | jq --arg pk "$PUB_BARE" '.attributes["jwt.credential.public.key"] = $pk' \
    | kubectl exec -i -n keycloak keycloak-0 -c keycloak -- sh -c 'cat > /tmp/rollback-client.json'
kubectl exec -n keycloak keycloak-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh \
    update clients/$KC_INT_ID -r secforge-tenants -f /tmp/rollback-client.json
kubectl exec -n keycloak keycloak-0 -c keycloak -- rm -f /tmp/rollback-client.json

# 5. Rolling-restart the BFF.
kubectl rollout restart -n app deployment/helloworld-bff
kubectl rollout status -n app deployment/helloworld-bff --timeout=180s
```

Then verify a fresh login passes (same checks as the success-verification section above). After confirming the rollback works, file an incident entry in the operator backlog and investigate the rotation failure root cause before re-attempting.

---

## Failure modes

### `client not found in realm secforge-tenants`

The script's pre-flight failed to resolve the client UUID. Either the realm is stale (re-import via `kubectl apply -f infrastructure/keycloak/realms/secforge-tenants-realm.yaml`) or the `clientId` argument was wrong. The script's allowlist accepts only the four canonical names.

### `deployment <bff> not found — is the BFF deployed yet?`

The script demands a real Deployment to roll-restart. If you're trying to "rotate" a key for a BFF that hasn't been deployed yet (e.g., `proposal-forge-bff` before Phase 10), don't — the cron is `suspend: true` for that exact reason. The OpenBao + Keycloak sides hold the original Phase 6.10b key; nothing reads it until the BFF lands.

### After rotation, login fails with `invalid_client: Unable to load public key`

This is the Phase 6b-0 finding ([PLAN.md line ~290](../../PLAN.md)): `jwt.credential.public.key` + `use.jwks.string=false` format had quirks in early Keycloak 26.x. The current Phase 6.10b bootstrap uses this exact scheme today and works; the rotation script preserves the scheme via JSON merge. If you see this error post-rotation, suspect:

- The PEM body got `\r\n` line endings somewhere along the path (the script strips them, but a custom rollback might not).
- A Keycloak upgrade changed the attribute parser shape — read the Keycloak 26.x release notes for the version running in your cluster.
- The Keycloak client is missing `use.jwks.url=false` and `use.jwks.string=false`. Check via `kcadm get clients/<id> -r secforge-tenants --fields 'attributes(use.jwks.url,use.jwks.string)'`.

### CronJob fails: `auth/jwt/login returned no client_token`

The OpenBao JWT role `bff-key-rotator` either isn't configured (run [`./configure-openbao-role.sh`](../../infrastructure/keycloak/realms/cron/configure-openbao-role.sh)) or the SPIFFE-ID bound on the role doesn't match the actual SVID the spiffe-helper minted. Check:

```bash
kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN=$BAO_TOKEN \
    bao read auth/jwt/role/bff-key-rotator
```

`bound_subject` should be `spiffe://secforge.local/ns/app/sa/bff-key-rotator`. The pod's SVID can be inspected via SPIRE Server's CLI; if it doesn't match, the namespace-scoped ClusterSPIFFEID for `app` may need an update.

### CronJob fails: `pods 'openbao-0' is forbidden`

The pod's RBAC is incomplete. Re-apply the manifest:
```bash
bash infrastructure/keycloak/realms/cron/apply.sh
```
And confirm the RoleBinding subjects reference SA `bff-key-rotator` in `app` ns:
```bash
kubectl get rolebinding -n openbao bff-key-rotator-openbao-exec -o yaml
```

### Rotation succeeds but the BFF still uses the old `kid`

The BFF reads OpenBao **only at startup**. If the Deployment didn't actually restart (e.g., `kubectl rollout restart` succeeded but the new pod is stuck in `ContainerCreating` or an init container fails), the old pod still serves traffic with the old key — but Keycloak now rejects assertions signed with that key.

Check pod status:
```bash
kubectl get pods -n app -l app.kubernetes.io/name=helloworld-bff
kubectl describe pod -n app -l app.kubernetes.io/name=helloworld-bff
```

If a pod is stuck on `wait-for-spiffe-csi`, the SPIFFE-CSI cold-boot race is biting again — see [`spire-rotation.md § cold-boot race`](./spire-rotation.md). The init container retries indefinitely; the rotation script's 180s timeout will expire before the new pod is `Ready`. Re-run the rotation once the pod comes up.

---

## Where this lives in the codebase

| File | Purpose |
|---|---|
| [`infrastructure/keycloak/realms/rotate-bff-key.sh`](../../infrastructure/keycloak/realms/rotate-bff-key.sh) | The rotation script (single source of truth; CronJob mounts a copy). |
| [`infrastructure/keycloak/realms/cron/wrapper.sh`](../../infrastructure/keycloak/realms/cron/wrapper.sh) | CronJob entrypoint: mints `BAO_TOKEN` via `auth/jwt/login`, execs the script. |
| [`infrastructure/keycloak/realms/cron/01-rotate-bff-key.yaml`](../../infrastructure/keycloak/realms/cron/01-rotate-bff-key.yaml) | All K8s resources (SA, RBAC, helper-conf ConfigMap, four CronJobs). |
| [`infrastructure/keycloak/realms/cron/configure-openbao-role.sh`](../../infrastructure/keycloak/realms/cron/configure-openbao-role.sh) | Configures the OpenBao JWT auth role `bff-key-rotator`. |
| [`infrastructure/keycloak/realms/cron/apply.sh`](../../infrastructure/keycloak/realms/cron/apply.sh) | Applies the manifest + builds the scripts ConfigMap from on-disk sources. |
| [`infrastructure/openbao/policies/bff-key-rotator.hcl`](../../infrastructure/openbao/policies/bff-key-rotator.hcl) | OpenBao policy for the rotator role. |
| [`infrastructure/keycloak/_lib/kcadm-auth.sh`](../../infrastructure/keycloak/_lib/kcadm-auth.sh) | kcadm-admin auth helper (shared with the four bootstrap scripts). |

---

## Bootstrap (fresh cluster)

```bash
# 1. Load OpenBao policy.
BAO_TOKEN=hvs.xxx bash infrastructure/openbao/load-policies.sh

# 2. Configure JWT role for the rotator.
BAO_TOKEN=hvs.xxx bash infrastructure/keycloak/realms/cron/configure-openbao-role.sh

# 3. Apply K8s resources (rebuilds scripts ConfigMap from on-disk sources).
bash infrastructure/keycloak/realms/cron/apply.sh

# 4. Verify.
kubectl get cronjob -n app -l app.kubernetes.io/name=bff-key-rotator
kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN=$BAO_TOKEN \
    bao read auth/jwt/role/bff-key-rotator
```
