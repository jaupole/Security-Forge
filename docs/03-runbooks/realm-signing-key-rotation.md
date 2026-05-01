# Realm Signing Key Rotation Runbook

> ADR: [0006 — Keycloak realm signing keys (local edition)](../02-decisions/0006-keycloak-keys-local.md)

Realm signing keys are the active asymmetric keypairs each realm uses to sign access tokens, ID tokens, and (when applicable) SAML assertions. The 90-day rotation cadence is operational hygiene — it ensures the rotation procedure is exercised before it ever has to run in a real incident.

This runbook applies to both `platform` and `secforge-tenants` realms. The procedure is the same.

---

## When to rotate

- **Routine**: every 90 days (calendar reminder).
- **Forced** (rotate immediately, do not wait for the calendar):
  - Suspected compromise of the realm's signing key (DB exfiltration, master encryption key exposure).
  - Departure of a person with realm admin access (precautionary; tightens the recovery surface).
  - Any change to the realm's master encryption key configuration.
  - Following the cloud-migration playbook (where rotation is to a KMS-backed key, not just a DB-backed re-roll).

---

## Procedure (90-day overlap rotation)

The active key keeps signing tokens. We add a NEW key with HIGHER priority — Keycloak picks the highest-priority active key for new signing operations. The OLD key remains in the JWKS as `passive` so existing tokens issued under it continue to verify until they expire.

### 1. Pre-flight

```bash
REALM=platform   # or secforge-tenants
KC=keycloak-0
NS=keycloak

# Snapshot current keys.
kubectl exec -n $NS $KC -- /opt/keycloak/bin/kcadm.sh get keys -r $REALM \
    | jq '.keys[] | {kid, providerId, status, type, algorithm, use, providerPriority}' \
    > /tmp/${REALM}-keys-pre-rotation-$(date +%Y%m%d).json
```

Verify you have at least one active RS256 sig key. If not, stop — there's a bigger problem to fix first.

### 2. Add a new RS256 key provider with priority 200

```bash
# Find the current default sig provider's id (we'll bump its priority later).
EXISTING=$(kubectl exec -n $NS $KC -- /opt/keycloak/bin/kcadm.sh \
    get components -r $REALM -q "providerType=org.keycloak.keys.KeyProvider,name=rsa-generated" \
    | jq -r '.[0].id')

# Add the new component.
kubectl exec -n $NS $KC -- /opt/keycloak/bin/kcadm.sh \
    create components -r $REALM \
    -s name=rsa-generated-rotated-$(date +%Y%m%d) \
    -s providerId=rsa-generated \
    -s providerType=org.keycloak.keys.KeyProvider \
    -s 'parentId='"$REALM" \
    -s 'config.priority=["200"]' \
    -s 'config.active=["true"]' \
    -s 'config.enabled=["true"]' \
    -s 'config.algorithm=["RS256"]' \
    -s 'config.keySize=["2048"]'
```

### 3. Verify the new key is in the JWKS

```bash
curl -sk https://auth.secforge.local/realms/$REALM/protocol/openid-connect/certs | jq '.keys[] | {kid, alg, use}'
```

You should see TWO `sig` keys with `alg: RS256` — the old one and the new one. Tokens issued from this point on use the new key; tokens issued before still verify against the old key (since both are advertised in JWKS).

### 4. Wait at least 5 minutes (one access-token TTL)

This ensures any in-flight tokens from the old key have a chance to verify and complete. In a high-traffic deployment, wait longer (e.g., one refresh-token lifetime) to drain.

### 5. Demote the old key to passive

The old `rsa-generated` component stays, but its `active` flag flips to `false`:

```bash
kubectl exec -n $NS $KC -- /opt/keycloak/bin/kcadm.sh \
    update components/$EXISTING -r $REALM \
    -s 'config.active=["false"]' \
    -s 'config.enabled=["true"]'
```

The key remains in JWKS (so verification still works for any token issued under the old key), but is no longer used for new signing.

### 6. Schedule the 30-day deletion

After 30 days, delete the old component:

```bash
# After 30 days...
kubectl exec -n $NS $KC -- /opt/keycloak/bin/kcadm.sh \
    delete components/$EXISTING -r $REALM
```

Set a calendar reminder. Until you delete the component, the old key sits in the JWKS as passive, which is harmless but clutters the discovery surface.

### 7. Update inventory

Append a row to `docs/03-runbooks/realm-signing-key-rotation-log.md` (create if missing):

| Date | Realm | Old kid | New kid | Notes |
|---|---|---|---|---|

---

## Post-rotation verification

```bash
# Both old and new keys present (status: ACTIVE for new, PASSIVE for old)
kubectl exec -n $NS $KC -- /opt/keycloak/bin/kcadm.sh \
    get keys -r $REALM | jq '.keys[] | {kid, status, providerPriority, algorithm, use}'

# JWKS still resolves
curl -sk https://auth.secforge.local/realms/$REALM/protocol/openid-connect/certs \
  | jq '.keys | length'   # ≥ 2 during overlap window

# Discovery still serves
curl -sk -o /dev/null -w "%{http_code}\n" \
  https://auth.secforge.local/realms/$REALM/.well-known/openid-configuration

# A fresh token signed under the new kid
# (run from a client that's already authenticated; the kid in the
# decoded JWT header should match the new component's kid)
```

---

## Cloud-edition variant (KMS-backed)

When migrating to cloud, this runbook is replaced by:

1. KMS-side key creation (AWS KMS / GCP KMS / Azure Key Vault).
2. Keycloak's `pkcs11` key provider component is updated to point to the new KMS key reference.
3. Same overlap window (5 min for new sign, 30 days for old verify).
4. The KMS key never leaves the HSM; nothing about Keycloak's storage changes.

The procedure structurally matches steps 2–6 above; only the component type differs (`pkcs11` vs `rsa-generated`).

---

## Troubleshooting

### "kid not found" errors from a resource server during rotation

The resource server is caching the JWKS too aggressively. Default cache TTL should be ≤ 5 min. If you control the resource server's library, set:

- Go (`go-oidc`): default verifier auto-refreshes; if you've set a custom transport, ensure it doesn't pin keys.
- Node (`jose`): pass `cache: true` and `cooldownDuration: 60` (seconds) — that bounds the staleness.
- Java (`nimbus`): use `RemoteJWKSet` with default `JWKSetCache` TTL = 5 min, refresh = 1 min.

If a downstream verifier is hard-cached, it will fail until restart. That's a verifier bug, not a rotation problem.

### Tokens signed under the new key are rejected by the BFF

If the BFF was running before rotation and is using a cached JWKS, it may not know about the new kid. Restart the BFF, or wait for its JWKS cache to expire.

### The new key didn't take priority

Check `providerPriority` on both components. If both are 100, Keycloak's pick is implementation-defined (likely the older one). Re-run step 2 with `priority=["200"]` and verify the new component's priority is higher.

### You accidentally deleted the active key

The realm now has no signing key. Tokens cannot be issued; existing tokens cannot verify (no JWKS). Add a fresh component immediately (step 2 above) — Keycloak generates new key material on creation. All previously-issued access tokens are dead; users will need to re-authenticate. Refresh tokens for the realm may also be invalidated depending on configuration.

This is a "do not let happen" event; the calendar reminder + the 30-day overlap window is the buffer that prevents it during routine ops.
