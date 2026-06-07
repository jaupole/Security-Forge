# Keycloak `platform` realm hardening replay (DR + drift fix)

> **TL;DR** — `KeycloakRealmImport` CR is one-shot. The 2026-05-14 hardening
> flips (passkey-mandatory browser flow, HIBP password blacklist, brute-force
> tightening, WebAuthn policy) were applied LIVE via kcadm and are NOT in the
> imported realm Secret. On a fresh DR cluster, the realm would come up with
> the pre-hardening config. This runbook covers re-applying the hardening
> idempotently via `platform/components/03a-keycloak-realm-hardening.sh`.

## When to run

- **After every cluster rebuild** (DR drill, migration, fresh-cluster bootstrap)
  — once Keycloak Operator has finished its initial realm import.
- **Periodically** as a drift check — the script is idempotent; if the realm
  is already hardened, every stage skips with `already X — skipping`.
- **After any manual `kcadm update realms/platform`** that changes a field the
  script also sets — to confirm the script's view still matches.

## Prerequisites

1. **Cluster reachable**, `kubectl` configured.
2. **Keycloak Operator Ready**, `keycloak-0` pod Running, initial
   `KeycloakRealmImport` reconciled (check `kubectl -n keycloak get keycloakrealmimport`).
3. **A real master-realm admin account** that you know the password for.
   `temp-admin` (from `keycloak-initial-admin` Secret) is normally Disabled
   after the post-bootstrap hardening — see below for recovery.
4. **HIBP password blacklist file present in the pod** at
   `/opt/keycloak/data/password-blacklists/Pwdb_top-100000.txt`. **Baked
   into the SecForge custom Keycloak image** (`ghcr.io/secforge/keycloak`)
   so on any cluster running that image the file is structurally present —
   the replay script's stage [01] fails loudly if it isn't, which means
   the running pod is on the wrong image.

   Refresh the blacklist by bumping `PWDB_COMMIT` + `PWDB_SHA256` in
   `platform/manifests/keycloak/image/Dockerfile` + merging. GHA rebuilds the
   image; bump `04-keycloak-cr.yaml` `spec.image` to the new digest.

   See `platform/manifests/keycloak/image/README.md` for the full image-refresh
   procedure.

## Procedure

### 1. Authenticate kcadm inside the keycloak-0 pod

**1a — Configure the kcadm truststore (first run + after every pod restart).**

`kcadm` runs on a JVM whose default truststore holds only public CAs. The
in-cluster endpoint presents the `keycloak-internal-tls` cert signed by the
private `secforge-internal-ca` CA, so `config credentials` fails with a
trust error before any password is even checked:

```
Failed to send request - PKIX path building failed:
sun.security.provider.certpath.SunCertPathBuilderException: unable to find
valid certification path to requested target
```

Hand kcadm a truststore that contains the internal CA. The truststore
config and the `/tmp` files live only in the `keycloak-0` pod and are lost
on pod restart — redo this whenever the pod has restarted:

```bash
# Pull the internal CA out of the TLS secret
kubectl -n keycloak get secret keycloak-internal-tls \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/secforge-ca.crt

# Stream it into the pod. `kubectl cp` needs tar, which the distroless
# Keycloak image does not ship — pipe over stdin instead.
kubectl -n keycloak exec -i keycloak-0 -- \
  sh -c 'cat > /tmp/secforge-ca.crt' < /tmp/secforge-ca.crt

# Build a PKCS12 truststore inside the pod. keytool ships with the JRE;
# if it is not on PATH it is at $JAVA_HOME/bin/keytool.
kubectl -n keycloak exec -i keycloak-0 -- sh -c '
  keytool -importcert -noprompt -alias secforge-internal-ca \
    -file /tmp/secforge-ca.crt \
    -keystore /tmp/kcadm-truststore.p12 -storetype PKCS12 -storepass changeit'

# Point kcadm at it
kubectl -n keycloak exec -i keycloak-0 -- /opt/keycloak/bin/kcadm.sh \
  config truststore --trustpass changeit /tmp/kcadm-truststore.p12
```

`auth.secforge.dev` carries a publicly-trusted Let's Encrypt cert and would
need no truststore — but the `keycloak` namespace has external egress
blocked, so an in-pod kcadm cannot hairpin out to its own public hostname.
The in-cluster service hostname plus this truststore is the working path.

**1b — Authenticate.**

```bash
kubectl -n keycloak exec -it keycloak-0 -- /opt/keycloak/bin/kcadm.sh \
  config credentials \
  --server https://keycloak-service.keycloak.svc.cluster.local:8443 \
  --realm master \
  --user <REAL_ADMIN_USERNAME>
# Prompts for password; cache lands in /opt/keycloak/.keycloak/kcadm.config
```

The credentials cache survives `exec` exit but — like the step 1a
truststore — is **lost on pod restart**. If the pod restarts mid-procedure,
redo both 1a and 1b.

**Server hostname matters** — must be one of the cert SANs:
- `keycloak-service.keycloak.svc.cluster.local` (use this from in-cluster)
- `keycloak-service.keycloak.svc`
- `keycloak-service`
- `auth.secforge.dev` (publicly trusted — but egress-blocked from in-pod)
- ✗ NOT `localhost`

### 2. Verify auth

```bash
kubectl -n keycloak exec keycloak-0 -- /opt/keycloak/bin/kcadm.sh get serverinfo --fields systemInfo
# Expected: a small JSON blob with systemInfo. Silence = success.
# Errors → re-auth.
```

### 3. Run the replay script

```bash
sudo /usr/local/bin/03a-keycloak-realm-hardening.sh
# or, from the repo:
sudo bash platform/components/03a-keycloak-realm-hardening.sh
```

The script prints a `>>> [NN] description` header before each stage. On a
clean cluster, every stage applies (you'll see field updates land). On an
already-hardened realm, the conditional stages all report
`already X — skipping`.

### 4. Verify final state

The script's last block dumps the realm's hardening-relevant fields. They
should match:

```json
{
  "browserFlow": "browser-webauthn-required",
  "passwordPolicy": "length(14) and digits(1) and lowerCase(1) and upperCase(1) and specialChars(1) and notUsername(undefined) and notEmail(undefined) and passwordHistory(5) and forceExpiredPasswordChange(365) and passwordBlacklist(Pwdb_top-100000.txt)",
  "webAuthnPolicyRpId": "secforge.dev",
  "webAuthnPolicyUserVerificationRequirement": "required",
  "failureFactor": 10,
  "maxFailureWaitSeconds": 3600,
  "waitIncrementSeconds": 120,
  "bruteForceProtected": true,
  "registrationAllowed": false,
  "ssoSessionIdleTimeout": 900,
  "ssoSessionMaxLifespan": 28800,
  "ssoSessionIdleTimeoutRememberMe": 28800,
  "ssoSessionMaxLifespanRememberMe": 86400
}
```

Session lifetimes: a regular session idles out after 15 min and is hard-capped
at 8 h. A "Remember Me" session (the login-page checkbox) idles out after 8 h
and is hard-capped at 24 h — tightened 2026-05-19 from the prior 7 d / 30 d
for production session hygiene.

Default required actions list should be:
```json
["CONFIGURE_RECOVERY_AUTHN_CODES", "webauthn-register"]
```

### 5. Smoke test

Open `https://auth.secforge.dev/realms/platform/account/` in a private
browser window. Sign in with a test user — you should be prompted for
WebAuthn (passkey/security key/platform authenticator), NOT TOTP. After
sign-in, the account page should show "Two-factor authentication" with
WebAuthn listed.

## Recovery — no admin password remembered

The `temp-admin` bootstrap account is disabled by design. If you've lost
all admin creds, bootstrap a new one inside the pod:

```bash
kubectl -n keycloak exec -it keycloak-0 -- \
  /opt/keycloak/bin/kc.sh bootstrap-admin user \
  --username recovery-admin --password '<temp-strong-pw>'
```

This requires Keycloak 24+ (this cluster runs 26). It creates a master-realm
admin user without needing existing creds. **Disable or delete this user
immediately after your work is done** to maintain the hardened posture.

## Cutting over from the legacy local image + ConfigMap

The 2026-05-14 hardening sprint left the cluster running
`localhost/secforge/keycloak:26.3.3-optimized` (built ad-hoc on the host,
nothing committed to repo) with the HIBP blacklist delivered via a
`keycloak-password-blacklist` ConfigMap mounted at
`/opt/keycloak/data/password-blacklists/`. Both arrangements are
unreproducible — a DR rebuild would lose them.

**Cutover steps (one-time):**

1. Push to `main` with the `platform/manifests/keycloak/image/Dockerfile` and
   the GHA workflow in `.github/workflows/keycloak-image-build.yml`. GHA
   builds the first signed image. Note the `@sha256:...` digest from the
   run summary.
2. Edit `platform/manifests/keycloak/04-keycloak-cr.yaml`: replace the
   placeholder digest in `spec.image` with the real one from step 1. Also
   `spec.startOptimized: true` (already set).
3. `kubectl apply -f platform/manifests/keycloak/04-keycloak-cr.yaml` —
   Keycloak Operator rolls the pod over to the new image.
4. Verify the pod is using the new image:
   ```bash
   kubectl -n keycloak get pod keycloak-0 -o jsonpath='{.spec.containers[*].image}'
   # expect: ghcr.io/secforge/keycloak@sha256:<digest>
   ```
5. Verify the blacklist file is still present (it should be — now baked
   in, not CM-mounted):
   ```bash
   kubectl -n keycloak exec keycloak-0 -- ls -la /opt/keycloak/data/password-blacklists/
   ```
6. Re-run this script to confirm everything still works post-cutover.
7. Remove the obsolete ConfigMap + volumeMount:
   ```bash
   kubectl -n keycloak delete cm keycloak-password-blacklist
   # If the Keycloak CR carries an additionalVolumes/additionalVolumeMounts
   # entry pointing at this CM, also remove that block from the CR + apply.
   ```

## What the script does NOT cover

- Client-level mappers (audience self-mappers per
  `project_keycloak_audience_mappers` memory). Those live in the realm
  import Secret and ARE re-applied by KeycloakRealmImport.
- Realm-level event listener config. Add stages to the script as they
  become hardening requirements.
- The `master` realm's own session timeouts (admin-console sessions).
  Stage [02] covers the `platform` realm's user-session lifetimes only;
  the `master` realm is hardened separately.

## Source-of-truth note

The script in `platform/components/03a-keycloak-realm-hardening.sh` is the
authoritative source of all post-import hardening. The
`KeycloakRealmImport` CR + `keycloak-platform-realm` Secret remain the
**baseline / structural** source (clients, roles, scopes, realm metadata).
Don't try to push hardening into the import Secret — KeycloakRealmImport's
one-shot semantics will defeat you on update.
