# Keycloak Operations Runbook

Day-2 operations for the production Keycloak on the single public Hetzner k3s node.

> Architecture: [docs/01-architecture/01-iam-platform.md](../01-architecture/01-iam-platform.md) ·
> Realm signing keys: [realm-signing-key-rotation.md](./realm-signing-key-rotation.md) ·
> Realm hardening replay: [keycloak-realm-hardening-replay.md](./keycloak-realm-hardening-replay.md) ·
> Master browser-flow replay: [keycloak-master-flow-replay.md](./keycloak-master-flow-replay.md) ·
> Client provisioning: [keycloak-client-provisioning.md](./keycloak-client-provisioning.md) ·
> ADRs: [0006](../02-decisions/0006-keycloak-keys-local.md), [0036](../02-decisions/0036-production-authentication-factors-passkeys.md)

## Live deployment (verify before acting)

| Fact | Value |
|---|---|
| Operator | Keycloak Operator 26.3.3 (`keycloak/keycloak-operator`) |
| Server image | `ghcr.io/jaupole/keycloak@sha256:…` — custom, GHA-built, **cosign-signed**, digest-pinned in `platform/manifests/keycloak/04-keycloak-cr.yaml`; admission-gated by Kyverno `verify-image-signature-secforge`. `spec.startOptimized: true` (build features baked into the image). |
| DB | CNPG `secforge-keycloak-db` (Postgres 17.6), pod `secforge-keycloak-db-1`, rw service `secforge-keycloak-db-rw.keycloak.svc` |
| Public OIDC host | `https://auth.secforge.dev` (public Istio gateway) |
| Admin console host | `https://kc.secforge.dev` — **tailnet-only** (`secforge-gateway-tailnet`; Kyverno `admin-ingress-must-be-tailnet-only`) |
| Realms | `platform` (operators/admins) + `secforge-tenants` (tenants) — both via `KeycloakRealmImport` (`platform-realm-import`, `secforge-tenants-realm-import`) |
| Auth factor | Passkeys — `platform` is `browser-webauthn-required` (mandatory passkey + recovery codes); `secforge-tenants` is `browser-flexible` (password-or-passkey + optional 2FA). TOTP removed. See [ADR-0036](../02-decisions/0036-production-authentication-factors-passkeys.md). |

## The admin model — read this first

**The master-realm admin is DB-only.** `jaupole` is the sole master-realm admin, WebAuthn-required,
with **no password on the box**. The temporary bootstrap admin was deleted 2026-05-21. The operator's
auto-provisioned `keycloak-initial-admin` Secret still exists but is functionally inert (Keycloak only
runs bootstrap-admin creation when *no* admin user exists) — leave it.

Consequences for automation:

- **`kcadm.sh` and admin-API `curl` are non-starters** for writes — there is no password or service
  account to authenticate them. Do **not** copy the old `kcadm`/`kcadm-admin` patterns; they were the
  local edition.
- **Scripted/automated Keycloak changes go via one of three paths:**
  1. **Realm-import** — edit the codified `…-realm.yaml` and re-apply (DR / wholesale; destructive — see below).
  2. **Codified replay scripts** — `platform/components/03a-keycloak-realm-hardening.sh` (realm
     hardening), `platform/components/05l-keycloak-secret-publish.sh` (publish operator-generated
     secrets to their destinations), the master browser-flow replay.
  3. **Direct Postgres writes** against `secforge-keycloak-db-1` for surgical changes, **followed by a
     `keycloak-0` pod bounce** to flush the Infinispan cache (direct DB writes do not invalidate it).
- **Interactive admin work** is done in the console at `https://kc.secforge.dev` over the tailnet,
  signing in as `jaupole` with the passkey. Read-only inspection (Evaluate tool, client config) is the
  main use; persistent config belongs in the codified manifests, not hand-edits.

## Reach the cluster

- SSH over the tailnet: `ssh secforge` (ops user). Run cluster commands as `sudo -n kubectl …` on the box.
- Admin console: `https://kc.secforge.dev` (tailnet-only) — passkey sign-in as `jaupole`.
- The box `~/secforge` is a git checkout; update it with `git pull --ff-only`, never scp.

## Realm management

The realm clients, WebAuthn policy, required actions, and the custom browser flows are **codified** in
the realm-import manifests (all 9 custom platform clients are in `platform-realm.yaml`; see
[keycloak-client-provisioning.md](./keycloak-client-provisioning.md)). `KeycloakRealmImport` is
**one-shot** — once a realm exists the operator's import job exits without re-applying.

### Re-apply a realm from its manifest (DR / wholesale — DESTRUCTIVE)

This wipes all users, sessions, and any non-codified config in the realm. Only for DR or a clean
re-provision. Back up the DB first (below).

```bash
# On the box. REALM is platform or secforge-tenants.
sudo kubectl delete -n keycloak keycloakrealmimport/${REALM}-realm-import
# then re-apply the manifest via the envsubst wrapper (never raw kubectl apply on platform/manifests):
platform/lib/apply-manifest.sh platform/manifests/keycloak/realms/${REALM}-realm.yaml
# After import, publish operator-generated client secrets to their destinations:
bash platform/components/05l-keycloak-secret-publish.sh
```

The custom Keycloak **image must be in use** before importing (the WebAuthn policy + password blacklist
are baked into it; stock upstream fails the import). `CLIENT.DESCRIPTION` is `varchar(255)` — keep
client descriptions short.

### Re-apply realm hardening only (non-destructive)

If realm hardening flips have drifted (e.g., after a partial restore), replay them idempotently
without touching users/clients:

```bash
bash platform/components/03a-keycloak-realm-hardening.sh
```

See [keycloak-realm-hardening-replay.md](./keycloak-realm-hardening-replay.md).

### Surgical change via direct Postgres write

For a one-off change the manifests don't cover, write directly to the DB, then **bounce the pod** so
Infinispan re-reads it:

```bash
sudo kubectl exec -n keycloak secforge-keycloak-db-1 -- \
  psql -U postgres keycloak -c "UPDATE … ;"          # the change
sudo kubectl rollout restart -n keycloak statefulset/keycloak   # flush Infinispan cache (the gotcha)
```

Then reflect the same change back into the codified manifest so it survives the next re-import.

## Client secret rotation

Rotating a confidential client's secret is an 8-step OpenBao + DB + pod-bounce sequence. The
non-obvious step is the **`keycloak-0` bounce to flush the Infinispan cache** — a direct DB write of the
new secret is not picked up until the pod restarts. First proven 2026-05-23 rotating the `member-hub`
and `member-hub-admin` client secrets. Outline:

1. Generate the new secret. 2. Write it to OpenBao at `secret/data/keycloak/clients/<client>`.
3. Update the client row in the Keycloak DB. 4. Update any consumer's stored copy (VSO / app secret).
5. Re-render the consumer secret. 6. Restart the consumer. 7. **`rollout restart statefulset/keycloak`**
(flush Infinispan). 8. Verify a token mint with the new secret.

> Every realm client also needs an `oidc-audience-mapper` adding its own `clientId` to the access-token
> `aud`, or strict `aud` checks 401 every token. The realm-import covers existing clients; add it for new ones.

## Read-only inspection

### Discovery document

```bash
curl -s https://auth.secforge.dev/realms/${REALM}/.well-known/openid-configuration | jq
```

### Realm signing keys (via JWKS, no admin auth needed)

```bash
curl -s https://auth.secforge.dev/realms/${REALM}/protocol/openid-connect/certs | jq '.keys[] | {kid, kty, alg, use}'
```

### Debug a "missing claim" — use the Evaluate tool FIRST

Before concluding a missing claim is a Keycloak misconfiguration, use the admin console's **Evaluate**
tool — it shows verbatim what Keycloak will emit, which usually proves the issuer side is correct and
the defect is on the consumer. (This is exactly how the OpenBao `realm_access/roles` issue was scoped:
Evaluate showed Keycloak emitting the claim correctly; the bug was the OpenBao userinfo-fetch path.)

In the console (`https://kc.secforge.dev`, tailnet):

1. Realm dropdown → the realm that issues the token (`platform` or `secforge-tenants`).
2. **Clients** → the client whose token you're debugging → **Client scopes** → **Evaluate**.
3. Pick the user, then switch between **Effective protocol mappers**, **Generated user info**,
   **Generated ID token**, **Generated access token**.

`realm_access.roles` is the usual offender (array under a nested object). If the Evaluate output is
correct but the consumer doesn't see the claim: confirm the consumer hits the right endpoint (userinfo
vs ID vs access token), then `curl` the same endpoint with the same Authorization header and diff
against Evaluate — if they match, the consumer's claim-extraction is the bug. This method applies to any
consumer (BFF ID-token parsing, OpenBao `bound_claims`, Grafana role mapping, Wazuh OIDC).

## Database backup & restore

```bash
# Ad-hoc CNPG backup (preferred — barman-cloud plugin):
sudo kubectl -n keycloak create -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { generateName: secforge-keycloak-db-adhoc-, namespace: keycloak }
spec:
  cluster: { name: secforge-keycloak-db }
  method: plugin
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
EOF
sudo kubectl -n keycloak get backup   # wait for PHASE=completed
```

Logical dump fallback / restore (destructive restore):

```bash
sudo kubectl exec -n keycloak secforge-keycloak-db-1 -- pg_dump -Fc -U postgres keycloak > /tmp/kc-$(date +%Y%m%d).dump
# restore:
sudo kubectl exec -i -n keycloak secforge-keycloak-db-1 -- pg_restore --clean -U postgres -d keycloak < /tmp/kc-DATE.dump
sudo kubectl rollout restart -n keycloak statefulset/keycloak
```

## Signed-image cutover & rollback

The IdP runs the GHA-built, cosign-signed image pinned by digest in `04-keycloak-cr.yaml`
(`spec.image → ghcr.io/jaupole/keycloak@sha256:…`), verified at admission by the Kyverno
`verify-image-signature-secforge` policy.

### Deploying an image change

1. Edit `platform/manifests/keycloak/image/Dockerfile`, merge — the `keycloak-image-build` GHA workflow
   builds, pushes and cosign-signs `ghcr.io/jaupole/keycloak`, printing the digest in its run summary.
2. Set `spec.image` in `04-keycloak-cr.yaml` to that digest; commit; push.
3. On the box: `cd ~/secforge && git pull --ff-only`, then
   `platform/lib/apply-manifest.sh platform/manifests/keycloak/04-keycloak-cr.yaml`. The Keycloak
   Operator rolls the StatefulSet (~1–3 min IdP downtime).

> Gotcha: `imagePullSecrets` go on the Keycloak **ServiceAccount**, not the CR podTemplate; the
> `keycloak` ns needs its own `ghcr-pull-secret` (same PAT as `control`). Use server-side apply on the CR.

### Pre-cutover safety net — run every time, before step 3

```bash
# 1. Snapshot the LIVE CR — the exact rollback target (live object, not the repo file).
sudo kubectl -n keycloak get keycloak keycloak -o yaml --show-managed-fields=false \
  > ~/keycloak-cr-rollback-$(date +%Y%m%d-%H%M).yaml
# 2. Fresh DB backup (wait for PHASE=completed) — see "Database backup" above.
# 3. Confirm the previous image is still on the node (Layer-1 rollback needs no rebuild).
sudo k3s ctr images ls | grep -E 'jaupole/keycloak'
```

### Layer 1 — revert the CR (seconds, non-destructive)

For "new pod won't start / Kyverno rejects it / Keycloak misbehaves". Re-apply the snapshot:

```bash
sudo kubectl -n keycloak apply -f ~/keycloak-cr-rollback-<TIMESTAMP>.yaml
sudo kubectl -n keycloak rollout status statefulset/keycloak --timeout=600s
```

The snapshot, not a git revert of the repo file, is the rollback artifact (it carries the previous
`spec.image` and any volume/mount the live object had). If `apply` reports a conflict, strip `status:`
and `metadata.resourceVersion`.

### Layer 2 — restore the database

For database-state damage (mainly a *version* bump, which runs schema migrations; a same-version digest
refresh runs none). Restore via the CNPG recovery flow: bootstrap a replacement Cluster with
`.spec.bootstrap.recovery` pointing at the pre-cutover `Backup`. Planned, IdP-down operation.

### Layer 3 — full DR

Velero/kopia cluster restore + `platform/components/03a-keycloak-realm-hardening.sh` to replay realm
hardening + `05l-keycloak-secret-publish.sh` to republish operator-generated secrets. Last resort. The
Tier-1 DR drill (2026-05-23) validated this path.

### Post-cutover verification

```bash
sudo kubectl -n keycloak get keycloak keycloak -o jsonpath='{.status.conditions}'
curl -s https://auth.secforge.dev/realms/master/.well-known/openid-configuration | jq -r .issuer
# Passkey login still works on the platform realm; a known-pwned password is still rejected on reset.
```

## Troubleshooting

### `503` from the gateway / app can't reach Keycloak

Keycloak pod is not Ready. `sudo kubectl -n keycloak get pod keycloak-0 -w`; if it doesn't recover in
5 min, check `sudo kubectl logs -n keycloak keycloak-0`. Ingress is the **Istio gateway** — the
allow policy is `allow-istio-ingress-to-keycloak` (not ingress-nginx).

### `Failed to obtain JDBC connection` / acquisition timeout

Keycloak can't reach Postgres. Check in order:

1. Postgres pod Ready: `sudo kubectl -n keycloak get pod secforge-keycloak-db-1`.
2. Free connection slots: `sudo kubectl exec -n keycloak secforge-keycloak-db-1 -- psql -U postgres -c 'SELECT count(*) FROM pg_stat_activity'`.
3. **NetworkPolicy.** `default-deny-ingress` applies to every pod in the namespace including Postgres.
   `allow-keycloak-to-postgres` must permit Keycloak + realm-import jobs to reach `:5432` on the pod
   selected by `cnpg.io/cluster: secforge-keycloak-db`. Verify it's present if you edited the policies.

### Realm import job stays Running > 5 min

The import job inherits Keycloak's pod template (~1700Mi request); check the keycloak-ns resource quota
and bump if needed. Also confirm the **custom Keycloak image** is in use (stock upstream fails the import
on the baked WebAuthn policy / password blacklist).

### `"Provided hostname-admin is not a valid URL"` on startup

`spec.hostname.admin` must be a full URL with scheme (`https://kc.secforge.dev`). Bare hostnames are
rejected by the v2 hostname provider in Keycloak 26.x. Live config: `admin=https://kc.secforge.dev`,
`hostname=https://auth.secforge.dev`, `strict=true`.

### `--optimized was used for first ever server start` / Quarkus re-augment errors

Production runs `spec.startOptimized: true` with the **pre-built custom image** (build features baked
in). If you switch to a non-baked image you must set `startOptimized: false` and `readOnlyRootFilesystem:
false` (Quarkus re-augments JARs on every start) — but the standing config is the baked image with
`startOptimized: true`, so prefer fixing the image.

## Account recovery

- **Operator lost their passkey:** the `platform` realm retains **recovery codes** as the fallback
  (sign in with a recovery code at `https://auth.secforge.dev/realms/platform/account`, then re-register
  a passkey and regenerate recovery codes). The master-realm admin (`jaupole`) is the break-glass for the
  realm-level config.
- **Tenant locked out:** the `secforge-tenants` realm has **no recovery codes** — the operator deletes
  or resets the user's credential and re-issues. Set this expectation with tenants up front.
