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
# Requires admin creds; provide TOTP code from your authenticator app.
KCADM_USER=jaupole KCADM_PASSWORD='your-password' KCADM_TOTP=123456 \
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
