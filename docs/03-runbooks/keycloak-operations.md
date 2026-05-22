# Keycloak Operations Runbook (Local Edition)

> Architecture: [docs/01-architecture/01-iam-platform.md](../01-architecture/01-iam-platform.md)
> Realm signing keys: [docs/03-runbooks/realm-signing-key-rotation.md](./realm-signing-key-rotation.md)
> ADRs: [0006](../02-decisions/0006-keycloak-keys-local.md), [0007](../02-decisions/0007-totp-instead-of-passkeys-locally.md)

This runbook covers day-2 operations for the Keycloak deployment in the SecForge local edition.

---

## Reach the cluster (assumed for everything below)

All commands assume:
- `kubectl` on PATH, default context = Docker Desktop K8s
- Working directory: `infrastructure/keycloak/`
- `auth.secforge.local` and `auth-admin.secforge.local` resolve to 127.0.0.1 (hosts file)
- mkcert local CA is trusted by the developer's browser

If any of those break, reset per [docs/00-getting-started/03-local-dns-and-tls.md](../00-getting-started/03-local-dns-and-tls.md).

---

## Phase 3.7 — first interactive login (one-time)

After Phase 3 deploy, you have:
- `master` realm with one user: `bootstrap-admin` (password printed once by `apply.sh`)
- `platform` realm with no users
- `secforge-tenants` realm with no users; four BFF clients pre-registered

Steps:

### 1. Open the admin console.

```
https://auth-admin.secforge.local/admin/master/console/
```

Browser may need the mkcert CA installed in Windows trust store. If you see a cert warning, fix that before proceeding.

### 2. Log in as bootstrap-admin.

Use the password printed by `infrastructure/keycloak/apply.sh`. It's not stored anywhere else; if you lost it, re-run:

```bash
kubectl -n keycloak delete secret keycloak-bootstrap-admin
bash infrastructure/keycloak/apply.sh    # generates a fresh one
```

Re-running `apply.sh` after deleting the secret prints a new bootstrap password and the operator picks it up on next reconcile.

### 3. Create your platform-realm user.

In the admin console, switch to the **`platform`** realm:

1. Top-left realm dropdown → `platform`
2. Users → "Create new user"
3. Username: your handle (no spaces)
4. Email: your email
5. **Required user actions** (check both):
   - `Configure OTP`
   - `Recovery Authentication Codes`
6. Save
7. Open the user → "Credentials" tab → "Set password" → set a temporary password, mark as Temporary
8. Save

### 4. Enroll TOTP and recovery codes.

Sign out of the admin console. Open the account console:

```
https://auth.secforge.local/realms/platform/account
```

(yes, the public host — the account console for platform-realm users belongs there, not on `auth-admin`)

Sign in with your new user + the temporary password. Keycloak will walk you through:

1. **TOTP enrollment.** Scan the QR with your authenticator app (1Password, Bitwarden, Authy, Google Authenticator, FreeOTP, Aegis). Enter the 6-digit code.
2. **Recovery codes.** 10 codes are displayed exactly once. **Save them in your password manager NOW** — there is no second display, and admin regeneration invalidates this set. Without these codes, "I lost my phone" means the platform admin has to delete and recreate your user.
3. **Update password.** If asked, set your real password.

### 5. Verify the new user has admin rights in the platform realm.

Log into the admin console with your new user (you'll be prompted for TOTP). Switch to the `platform` realm; confirm you can manage users.

### 6. Delete the bootstrap admin.

You also need a TOTP-enrolled admin in the **master** realm (not just the platform realm) — otherwise you can't manage realm-level config. Create one in the admin console first (master → Users → "Create new user", email + required actions [Configure OTP, Recovery Authentication Codes], assign role `admin` and `create-realm`), then enroll TOTP for that user via the master account console (`https://auth.secforge.local/realms/master/account`).

Once your master-realm and platform-realm users are both TOTP-enrolled and you've verified you can log in as them:

```bash
# 1. Remove the custom bootstrapAdmin block from the Keycloak CR. The
#    operator will switch the StatefulSet's env vars to reference its
#    own auto-generated Secret (keycloak-initial-admin) and roll the pod.
#    Edit infrastructure/keycloak/04-keycloak-cr.yaml — delete the
#    `bootstrapAdmin: { user: { secret: keycloak-bootstrap-admin } }`
#    block (already done as of 2026-04-29; left here as reference).
#
# 2. Apply and wait for the new pod to be Ready.
kubectl apply -f infrastructure/keycloak/04-keycloak-cr.yaml
kubectl rollout status -n keycloak statefulset/keycloak --timeout=300s

# 3. Delete the master-realm user (kcadm using the still-valid Secret).
BOOTSTRAP_PW=$(kubectl get secret -n keycloak keycloak-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh \
    config credentials --server http://localhost:8080 --realm master \
    --user bootstrap-admin --password "$BOOTSTRAP_PW"
unset BOOTSTRAP_PW

BA_ID=$(kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh \
    get users -r master -q username=bootstrap-admin --fields id --format csv --noquotes \
    | tr -d '\r' | head -1)
kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh \
    delete "users/$BA_ID" -r master

# 4. Delete the bootstrap Secret.
kubectl -n keycloak delete secret keycloak-bootstrap-admin
```

After this, the bootstrap admin path you control is closed. Recovery is via your own master/platform realm users + TOTP + recovery codes.

**Operator quirk to know about — `keycloak-initial-admin` Secret.** The Keycloak Operator always provisions a Secret called `keycloak-initial-admin` when no `bootstrapAdmin` is specified in the CR. It contains randomly-generated credentials and is referenced from the StatefulSet env (`KC_BOOTSTRAP_ADMIN_*` with `Optional: false`). Don't fight it — even if you delete it, the operator recreates it within ~30s. The credentials it holds are functionally inert because the master realm already has admin users (Keycloak's bootstrap-admin creation logic only runs if **no** admin user exists). It exists only so the StatefulSet's env refs always resolve. Leave it in place.

If you want to take an extra step against this Secret being a hidden credential surface, you can rotate it by deleting it (`kubectl -n keycloak delete secret keycloak-initial-admin`) — the operator regenerates with a fresh random password.

---

## Common operations

### Re-run automated verification

```bash
# Anonymous mode — discovery, JWKS, K8s resources, NetworkPolicies, pod hardening, bootstrap-admin teardown.
bash infrastructure/keycloak/verify.sh

# Full mode — also validates BFF client config and required actions.
# Requires kcadm-admin auth (per ADR-0022); supply BAO_TOKEN with read
# capability on secret/data/keycloak/clients/kcadm-admin.
BAO_TOKEN=hvs.xxxx \
    bash infrastructure/keycloak/verify.sh
```

Exits non-zero on any failure. Run after any change to Keycloak CR, realm imports, BFF clients, or NetworkPolicies.

### Re-import a realm (destructive)

`KeycloakRealmImport` is idempotent in the "first creation" sense — once a realm exists, the operator's import job exits without re-applying. To re-apply changes from `realms/*-realm.yaml`:

```bash
# 1. EXPORT current realm state to a backup file (do NOT skip).
kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh \
    get realms/REALM-NAME > /tmp/realm-backup-$(date +%s).json

# 2. Delete the realm.
kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh \
    delete realms/REALM-NAME

# 3. Delete the prior import job + KeycloakRealmImport CR + secret.
kubectl delete -n keycloak job/REALM-NAME-realm-import || true
kubectl delete -n keycloak keycloakrealmimport/REALM-NAME-realm-import || true
kubectl delete -n keycloak secret/keycloak-REALM-NAME-realm || true

# 4. Re-apply.
kubectl apply -f infrastructure/keycloak/realms/REALM-NAME-realm.yaml
```

This destroys all users, roles, sessions, and clients in the realm. **For non-destructive tweaks, edit the realm via the admin console or kcadm.sh and update `realms/*-realm.yaml` to match for documentation parity.**

### Update a BFF client config

Edit `infrastructure/keycloak/realms/bootstrap-bff-clients.sh` (the embedded JSON), then re-run:

```bash
bash infrastructure/keycloak/realms/bootstrap-bff-clients.sh
```

The script is idempotent — existing clients are updated in place.

### Rotate a BFF client signing key

```bash
# Identify the client.
CLIENT_ID=helloworld-bff
SECRET=bff-jwt-${CLIENT_ID}

# Delete the K8s Secret. Re-running the bootstrap script generates fresh keys
# and updates the Keycloak client's `jwt.credential.public.key` attribute.
kubectl delete secret -n app "${SECRET}"
bash infrastructure/keycloak/realms/bootstrap-bff-clients.sh
```

The old key is gone; the new public key is registered in Keycloak. The BFF (when it eventually exists) needs to pick up the new private key from the Secret on its next reload.

### Enroll a new admin user

1. Admin console → `master` realm → Users → "Create new user"
2. Username, Email, mark as Enabled
3. Required user actions: `Configure OTP`, `Recovery Authentication Codes`
4. Credentials tab → set a temporary password
5. Role mapping → assign realm role `admin` (or specific roles per the principle of least privilege)

Or via kcadm:

```bash
kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh \
    create users -r master \
    -s username=NEW-USERNAME \
    -s email=NEW-EMAIL \
    -s enabled=true \
    -s "requiredActions=[\"CONFIGURE_TOTP\",\"CONFIGURE_RECOVERY_AUTHN_CODES\"]"
```

### Recover access if you lost your TOTP authenticator

1. Open the account console at `https://auth.secforge.local/realms/<your-realm>/account`
2. Username → "Sign in with recovery code" link on the OTP prompt
3. Enter one of your saved recovery codes
4. Once in: Account console → Signing in → remove the old TOTP, register a new one
5. Generate fresh recovery codes (under "Account security" → Recovery Authentication Codes → Regenerate). The old codes are invalidated.

### Recover access if you lost both TOTP **and** recovery codes

This is the lockout case. There is no self-service path — by design.

For the project owner during the local-dev window, the workflow is:

1. Re-create the bootstrap admin secret (apply.sh after deleting the existing Secret).
2. Use bootstrap-admin to delete the locked-out user and re-enroll.

For tenant users: the platform admin deletes their account (or removes their TOTP credential) and re-issues. Document this expectation to tenants up front.

### Backup the Keycloak DB

```bash
kubectl exec -n keycloak secforge-keycloak-db-1 -- pg_dump -Fc -U keycloak keycloak > /tmp/kc-$(date +%Y%m%d).dump
```

Restore (destructive):

```bash
kubectl exec -i -n keycloak secforge-keycloak-db-1 -- pg_restore --clean -U keycloak -d keycloak < /tmp/kc-DATE.dump
kubectl rollout restart -n keycloak statefulset/keycloak
```

### Get a fresh discovery doc

```bash
curl -ks https://auth.secforge.local/realms/REALM/.well-known/openid-configuration | jq
```

### Inspect realm signing keys

```bash
kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh \
    get keys -r REALM | jq '.keys[] | {kid, providerId, status, type, algorithm, use}'
```

---

## Troubleshooting

### `503 Service Temporarily Unavailable` from ingress-nginx

Keycloak pod is not Ready. Wait for it (`kubectl -n keycloak get pod keycloak-0 -w`). If it doesn't recover in 5 min, check logs (`kubectl logs -n keycloak keycloak-0`).

### `Failed to obtain JDBC connection` / `Acquisition timeout while waiting for new connection`

Keycloak can't reach Postgres. Check in this order:

1. Postgres pod is Ready: `kubectl -n keycloak get pod secforge-keycloak-db-1`. If not, fix that first.
2. Postgres has free connection slots: `kubectl exec -n keycloak secforge-keycloak-db-1 -- psql -U postgres -c 'SELECT count(*) FROM pg_stat_activity'`. If near `max_connections`, restart any other clients drinking the pool.
3. **NetworkPolicy is allowing TCP/5432 ingress to the Postgres pod.** This is the gotcha. `default-deny-ingress` (selector `{}`) applies to every pod in the keycloak namespace, **including Postgres**. The `allow-postgres-ingress` NetworkPolicy permits Keycloak + realm-import jobs to reach 5432; if you've edited `07-networkpolicies.yaml`, verify that policy is still present and selects the Postgres pod via `cnpg.io/cluster: secforge-keycloak-db`.

   Probe from a same-namespace pod (PSS-restricted):

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata: { name: pg-probe, namespace: keycloak, labels: { app: keycloak } }
   spec:
     restartPolicy: Never
     securityContext: { runAsNonRoot: true, runAsUser: 70, seccompProfile: { type: RuntimeDefault } }
     containers:
     - name: probe
       image: postgres:16-alpine
       command: [sleep, "120"]
       securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] }, seccompProfile: { type: RuntimeDefault } }
   EOF
   kubectl exec -n keycloak pg-probe -- nc -zv secforge-keycloak-db-rw.keycloak.svc.cluster.local 5432
   kubectl delete pod -n keycloak pg-probe
   ```

   Probe pod must carry `app: keycloak` label so it's selected by the egress allow policy. If `nc` says "open", connectivity is fine and the issue is elsewhere (auth, JDBC config). If "Connection refused" or hangs, NetworkPolicy is the cause.

### Realm import job stays Running for >5 min

Check resource quota on the keycloak namespace — import jobs inherit Keycloak's pod template (~1700Mi memory request) and quota may be too tight. See `infrastructure/namespaces/namespaces.yaml` for the current limit; bump if needed and re-apply.

### "Provided hostname-admin is not a valid URL" on Keycloak startup

The Keycloak CR's `spec.hostname.admin` must be a full URL with scheme (`https://...`). Bare hostnames are rejected by the v2 hostname provider in Keycloak 26.x.

### `--optimized was used for first ever server start`

You enabled a build-time feature (e.g., `dpop`, `recovery-codes`) without setting `spec.startOptimized: false` on the Keycloak CR, OR you're using a custom image that wasn't pre-built. For the local edition we use `startOptimized: false`; the cloud edition will switch to a custom image with build features baked in.

### Quarkus `ReadOnlyFileSystemException` on first start

`readOnlyRootFilesystem` is too tight for `startOptimized: false` (Quarkus re-augments JARs on every start). Set `readOnlyRootFilesystem: false` on the Keycloak container; the rest of the hardening (no privesc, drop ALL caps, non-root, seccomp) stays. Documented in [iam-platform.md "Pod security"](../01-architecture/01-iam-platform.md).

### Cannot reach `auth-admin.secforge.local` from your laptop

The admin Ingress has a `whitelist-source-range` annotation. On Docker Desktop, requests from your laptop appear to ingress-nginx with source IPs from `172.19.0.0/16` (the docker0 bridge). If your bridge subnet differs, update the annotation in `06-ingress-admin.yaml`.

To inspect what nginx sees:

```bash
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=20 | grep auth-admin
```

The first field on each line is the source IP nginx applied the allowlist against.

---

## OIDC userinfo claim debug — `realm_access.roles` missing in OpenBao

**Symptom.** OpenBao OIDC role with `bound_claims: {"realm_access/roles": ["platform_admin"]}` fails login with:

```
Vault login failed.
error validating claims: claim "realm_access/roles" is missing
```

Even though Keycloak's `roles` client scope is attached to the `openbao` client as Default and the `realm roles` mapper has `Add to userinfo: ON`.

**Diagnosis: use Keycloak's Evaluate tool.** This is the definitive source for "what does Keycloak emit for this user via this client":

1. Browser → `https://auth-admin.secforge.local`
2. Realm dropdown → `platform`
3. Clients → `openbao` → top tabs → **Client scopes** → **Evaluate** sub-tab/button
4. Pick the user (`jason.upole`), click Evaluate
5. Switch between **Generated user info**, **Generated id token**, **Generated access token**

**Phase 7.0.b finding (2026-04-30).** All three Evaluate outputs include:

```json
"realm_access": {
  "roles": ["offline_access", "uma_authorization", "default-roles-platform", "platform_admin"]
}
```

…meaning Keycloak IS emitting the claim, with `platform_admin` present. Yet OpenBao 2.5.3 reports it missing during the actual auth flow. Conclusion: **defect is on the OpenBao side**, not Keycloak. The `preferred_username` workaround in `infrastructure/openbao/configure-auth-oidc.sh` remains in place; same for Grafana's `role_attribute_path` in `infrastructure/observability/01-kube-prometheus-stack-values.yaml`. Tracked in PLAN.md follow-up #1; defer per the 90-day fallback trigger 2026-07-29.

**If you need to extend this debug:** OpenBao 2.5.3 ignores `verbose_oidc_logging` (silently — it's a Vault Enterprise feature). To capture the actual userinfo response OpenBao receives, mint an access_token via `client_credentials` against the openbao client and curl `https://auth.secforge.local/realms/platform/protocol/openid-connect/userinfo` with that token; compare the response body to what OpenBao's role rejects.

---

## Verifying claim plumbing with the Keycloak Evaluate tool

**Use this BEFORE concluding a missing-claim is a Keycloak misconfig.** Phase 7.0.b's investigation surfaced the canonical example: OpenBao reported `realm_access/roles` missing during auth; the Keycloak Evaluate tool conclusively showed Keycloak was emitting it correctly in all three token outputs. The defect was on the OpenBao consumer side (upstream bug, not our config). Without the Evaluate tool's evidence, the investigation would have churned in Keycloak's realm/scope/mapper config indefinitely.

### Where to find it

In the Keycloak admin UI:

1. Realm dropdown (top-left) → choose the realm that issues the token (`platform` or `secforge-tenants`).
2. Left nav → **Clients** → click the client whose token shape you're debugging (`openbao`, `helloworld-bff`, `grafana`, `wazuh-dashboard` once provisioned, etc.).
3. Tab row at top of the client page → **Client scopes**.
4. Below the assigned-scopes list → **Evaluate** (a sub-tab next to "Setup").

### What the panes show

The Evaluate page has four output panes you can switch between (selector top-right):

| Pane | What it shows | When to read it |
|---|---|---|
| **Effective protocol mappers** | The full mapper list contributed by every scope assigned to this client (Default + Optional + the scopes you toggle on the left). Read this first to understand what Keycloak intends to emit before any token is minted. |
| **Generated user info** | The exact JSON that Keycloak's userinfo endpoint will return for the selected user. Compare against what your consumer's user-info-fetch logs claim it received. |
| **Generated ID token** | The exact JSON inside the ID token's payload. Useful when an OIDC client validates ID-token claims directly (e.g. the BFF's `claims.PreferredUsername` binding). |
| **Generated access token** | The exact JSON inside the access token's payload. Useful for backend APIs that gate on `aud` or scoped claims. |

### How to read multivalued claims

`realm_access.roles` is the most common offender — it's an array under a nested object:

```json
"realm_access": {
  "roles": ["default-roles-platform", "offline_access", "platform_admin"]
}
```

Some consumers expect this flattened (`"roles": [...]`) or differently-cased (`"realmRoles"`). The Evaluate tool's output is verbatim what Keycloak will emit — if your consumer expects a different shape, the bug is on the consumer side OR the consumer expects a transformation Keycloak should be configured to do (e.g., a hardcoded-claim mapper to flatten).

### What "claim is in Evaluate output but not consumed downstream" implies

**Downstream defect, not Keycloak misconfig.** Stop debugging the realm/scope/mapper and pivot to:

1. Confirm the consumer is hitting the right endpoint (userinfo vs ID token vs access token).
2. Capture what the consumer's HTTP path is actually receiving — direct curl to the same endpoint with the same Authorization header, then diff the JSON against the Evaluate output.
3. If they match: the consumer's claim-extraction logic is the bug.
4. If they don't match: there's an issuer-side detail the Evaluate tool didn't surface (rare; usually means a request-scoped claim mapper that depends on auth context the Evaluate tool can't simulate, OR a Quarkus-vs-classic Keycloak engine difference).

This was the F-ADR-7-adjacent learning from Phase 7.0.b: the Evaluate tool's output convinced us within minutes that the claim plumbing was correct on Keycloak's side. The investigation pivoted to OpenBao 2.5.3's userinfo-fetch path and the upstream defect was scoped within an hour.

### Reusable across the platform

This section applies to ANY consumer reporting a missing claim:
- BFF reading ID-token claims (Phase 6, `apps/lib/oidc/keycloak.go::ParseIDToken`)
- OpenBao OIDC role validating `bound_claims` (Phase 5)
- Grafana role mapping (Phase 7.3)
- Wazuh dashboard once OIDC federation lands (Phase 7d follow-up)

Any future "missing claim" debug starts with the Evaluate tool BEFORE assuming Keycloak's config is at fault.

---

## The kcadm-admin pattern (per ADR-0022)

Every kcadm-driven script in `infrastructure/keycloak/` authenticates as the `kcadm-admin` service-account client in the master realm. The pattern replaces the broken password+TOTP-concat approach (kcadm 26.x dropped `--otp`); details and rationale are in [ADR-0022](../02-decisions/0022-kcadm-admin-long-lived-credential.md).

### One-time bootstrap (operator-driven, manual UI)

The chicken-and-egg case: the provisioning script needs `kcadm-admin` to authenticate, but the client doesn't yet exist on a fresh install. So the very first creation is a manual step:

1. Open `https://auth-admin.secforge.local/admin/master/console/`.
2. Realm: `master` → **Clients → Create client**.
   - Client ID: `kcadm-admin`
   - Client authentication: **ON**
   - Authorization: **OFF**
   - Standard flow: **OFF**
   - Direct access grants: **OFF**
   - Implicit flow: **OFF**
   - Service accounts roles: **ON**
3. Save. Open **Credentials** tab → copy the generated **Client secret**.
4. Write the secret into OpenBao:

   ```bash
   kubectl exec -n openbao openbao-0 -c openbao -- \
       env BAO_TOKEN=$ROOT_TOKEN \
       bao kv put secret/keycloak/clients/kcadm-admin \
           client_secret='THE-COPIED-SECRET-VALUE'
   ```

5. Run `infrastructure/keycloak/clients/kcadm-admin.sh` (without `--rotate`) to apply the role grants from ADR-0022's "Roles granted" table.

### Fetching the secret (every script run)

Each migrated script (`verify.sh`, `clients/openbao.sh`, `realms/bootstrap-bff-clients.sh`, `realms/create-tenant-test-user.sh`) sources `infrastructure/keycloak/_lib/kcadm-auth.sh` and calls `kcadm_admin_auth`. The helper reads the secret from OpenBao via `kubectl exec` into `openbao-0` (option (b) from ADR-0022). All you need to provide is `BAO_TOKEN`:

```bash
# Mint a short-lived OpenBao token with read on the kcadm-admin path.
# Use a 5-min TTL — the script needs it once per run.
BAO_TOKEN=$(kubectl exec -n openbao openbao-0 -c openbao -- \
    env BAO_TOKEN=$ROOT_TOKEN \
    bao token create -policy=kcadm-admin-reader -ttl=5m \
        -field=token)

# Run any of the four migrated scripts.
BAO_TOKEN=$BAO_TOKEN bash infrastructure/keycloak/verify.sh
BAO_TOKEN=$BAO_TOKEN bash infrastructure/keycloak/clients/openbao.sh
BAO_TOKEN=$BAO_TOKEN bash infrastructure/keycloak/realms/bootstrap-bff-clients.sh
BAO_TOKEN=$BAO_TOKEN bash infrastructure/keycloak/realms/create-tenant-test-user.sh
```

The `kcadm-admin-reader` policy needs only:

```hcl
path "secret/data/keycloak/clients/kcadm-admin" {
  capabilities = ["read"]
}
```

### Rotation procedure (90-day cadence per ADR-0022)

```bash
# 1. Mint an OpenBao token with read+write on the kcadm-admin KV path.
BAO_TOKEN=$(kubectl exec -n openbao openbao-0 -c openbao -- \
    env BAO_TOKEN=$ROOT_TOKEN \
    bao token create -policy=kcadm-admin-rotator -ttl=15m \
        -field=token)

# 2. Run the provisioning script with --rotate.
BAO_TOKEN=$BAO_TOKEN \
    bash infrastructure/keycloak/clients/kcadm-admin.sh --rotate

# 3. Smoke-test against a representative migrated script.
BAO_TOKEN=$BAO_TOKEN \
    bash infrastructure/keycloak/verify.sh
```

The `kcadm-admin-rotator` policy needs `["read", "update"]` on `secret/data/keycloak/clients/kcadm-admin`.

The script regenerates the secret in Keycloak, writes the new value back to OpenBao at the same KV path, and re-authenticates under the new secret so the in-script role-grant reconciliation runs cleanly. On the rare case where Keycloak rotates but the OpenBao write fails, the script surfaces a manual-recovery `kubectl exec ... bao kv put …` command rather than leaving the operator guessing.

**90-day calendar reminder:** set a recurring task to rotate every 90 days. The provisioning script prints the next-due date on success.

### Adding a new kcadm-using script

When you write a new script that needs to perform Keycloak admin operations:

1. **Identify the realms + roles your script needs.** Run kcadm verbs by hand against a test realm to discover the smallest set of roles that lets every operation succeed. Don't grant `manage-realm` if `manage-clients` suffices.
2. **Append to ADR-0022 § "Roles granted" table.** Add a "Roles added 2026-MM-DD" note explaining what the new script does.
3. **Extend `ROLE_GRANTS` in `infrastructure/keycloak/clients/kcadm-admin.sh`.** Match the ADR table verbatim.
4. **Re-run `kcadm-admin.sh`** (without `--rotate`) to grant the new roles to the kcadm-admin service account. Idempotent.
5. **Source `_lib/kcadm-auth.sh` in your new script** and call `kcadm_admin_auth` before any kcadm verb. Don't re-implement the fetch+auth — it's centralized so all scripts stay in lockstep.

The role-review discipline keeps kcadm-admin's blast radius bounded. A script that needs `cluster-admin`-equivalent privilege is a smell — split it into smaller scripts or re-architect to use the Keycloak Operator's CRDs.

### When kcadm-admin auth fails

The helper's error message points at three likely causes; verify each in order:

1. **Stale secret in OpenBao** — someone rotated the Keycloak-side secret without running this runbook's rotation procedure. Symptom: `kcadm config credentials` returns `401 unauthorized: Invalid client credentials`. Fix: rotate via the runbook procedure above (the rotation procedure handles the regenerate-and-write-back atomically).
2. **kcadm-admin client doesn't exist** — fresh install where the bootstrap UI step hasn't been done. Symptom: `kcadm config credentials` returns `401: Invalid client credentials` AND the master realm's admin console shows no `kcadm-admin` client. Fix: do the one-time bootstrap procedure above.
3. **`serviceAccountsEnabled=false`** — someone toggled the client setting via the UI. Symptom: `kcadm config credentials` returns `401: Invalid grant: client requires service-account flow`. Fix: re-enable in the master-realm admin console under Clients → kcadm-admin → Settings → Service accounts roles.

---

## Signed-image cutover & rollback — platform / bare-metal edition

> **Edition note.** This section covers the bare-metal `platform/` deployment
> (`platform/manifests/keycloak/`, host `auth.secforge.dev`, single-node k3s on
> the Hetzner box). Everything above predates that edition and still describes
> the retired Local Edition (`infrastructure/keycloak/`, `auth.secforge.local`,
> Docker Desktop) — treat it as historical until this runbook is rewritten.

The IdP runs the GHA-built, cosign-signed image pinned by digest in
`04-keycloak-cr.yaml` (`spec.image` → `ghcr.io/jaupole/keycloak@sha256:…`),
verified at admission by the Kyverno `verify-image-signature-secforge` policy.
Build + deploy + refresh is operator-backlog #48.

### Deploying an image change

1. Edit `platform/manifests/keycloak/image/Dockerfile`, merge — the
   `keycloak-image-build` GHA workflow builds, pushes and cosign-signs
   `ghcr.io/jaupole/keycloak`, printing the digest in its run summary.
2. Set `spec.image` in `04-keycloak-cr.yaml` to that digest; commit; push.
3. On the box: `cd ~/secforge && git pull --ff-only`, then
   `platform/lib/apply-manifest.sh platform/manifests/keycloak/04-keycloak-cr.yaml`.
   The Keycloak Operator rolls the StatefulSet (~1–3 min IdP downtime).

### Pre-cutover safety net — run every time, before step 3

```bash
# 1. Snapshot the LIVE CR — this is the exact rollback target. Snapshot the
#    live object, NOT the repo file: the repo file can be drifted from live.
sudo kubectl -n keycloak get keycloak keycloak -o yaml --show-managed-fields=false \
  > ~/keycloak-cr-rollback-$(date +%Y%m%d-%H%M).yaml

# 2. Fresh DB backup. Wait for PHASE=completed before proceeding.
sudo kubectl -n keycloak create -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  generateName: secforge-keycloak-db-precutover-
  namespace: keycloak
spec:
  cluster: { name: secforge-keycloak-db }
  method: plugin
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
EOF
sudo kubectl -n keycloak get backup   # confirm the new one reaches 'completed'

# 3. Confirm the previous image is still on the node (Layer-1 rollback needs
#    no rebuild) and the blacklist ConfigMap still exists.
sudo k3s ctr images ls | grep -E 'secforge/keycloak|jaupole/keycloak'
sudo kubectl -n keycloak get cm keycloak-password-blacklist
```

### Layer 1 — revert the CR (seconds, non-destructive)

For "the new pod won't start / Kyverno rejects it / Keycloak misbehaves".
Re-apply the snapshot taken above:

```bash
sudo kubectl -n keycloak apply -f ~/keycloak-cr-rollback-<TIMESTAMP>.yaml
sudo kubectl -n keycloak rollout status statefulset/keycloak --timeout=600s
```

The snapshot carries the previous `spec.image` *and* — if rolling back from
the baked-blacklist image to one that expects the ConfigMap mount — the
`password-blacklist` volume/mount. That is why the snapshot, not a git
revert of the repo file, is the rollback artifact. If `apply` reports a
conflict, strip `status:` and `metadata.resourceVersion` from the file.

### Layer 2 — restore the database

For database-state damage — relevant mainly to a Keycloak *version* bump,
which runs schema migrations; a same-version base-digest refresh runs none.
Restore via the CNPG recovery flow: bootstrap a replacement Cluster with
`.spec.bootstrap.recovery` pointing at the pre-cutover `Backup`
(`secforge-keycloak-db-pre-48-cutover` or the latest `…-precutover-…`).
Planned, IdP-down operation.

### Layer 3 — full DR

Velero/kopia cluster backup + `platform/components/03a-keycloak-realm-hardening.sh`
to replay realm hardening. Last resort.

### Post-cutover verification

```bash
sudo kubectl -n keycloak get keycloak keycloak -o jsonpath='{.status.conditions}'
curl -s https://auth.secforge.dev/realms/master/.well-known/openid-configuration | jq -r .issuer
# Password blacklist still enforced: a known-pwned password must be rejected
# on a test password-set / reset flow.
```

Only once verified: delete the `keycloak-password-blacklist` ConfigMap and
remove the kaniko `image-build/` manifests (operator-backlog #48 cleanup).
