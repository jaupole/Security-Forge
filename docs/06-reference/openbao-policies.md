# OpenBao Policy Reference

> Architecture: [docs/01-architecture/05-secrets-management.md](../01-architecture/05-secrets-management.md)
> Source-of-truth files: [`infrastructure/openbao/policies/`](../../infrastructure/openbao/policies/)

The platform's three policies, what they grant, and how to extend.

---

## `admin`

Source: [`infrastructure/openbao/policies/admin.hcl`](../../infrastructure/openbao/policies/admin.hcl)

```hcl
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
```

**Mapped to:**
- Keycloak realm role `platform_admin` via `auth/oidc/role/admin`
  - currently bound by `preferred_username=jason.upole` ([known follow-up #31](#follow-ups) re-binds to `realm_access.roles=platform_admin` once the claim-emission is fixed)
- `auth/kubernetes/role/admin-break-glass` bound to the openbao ServiceAccount

**Use:** general platform administration. Not granted to workloads — workloads use scoped policies like `helloworld-bff`.

---

## `reader`

Source: [`infrastructure/openbao/policies/reader.hcl`](../../infrastructure/openbao/policies/reader.hcl)

```hcl
path "secret/data/users/{{identity.entity.name}}/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/users/{{identity.entity.name}}/*" {
  capabilities = ["read", "list"]
}
```

**Mapped to:** `auth/oidc/role/reader` (default for any platform-realm user without `platform_admin`).

**Use:** lets a non-admin platform user read their own per-user KV namespace under `secret/users/<their-username>/*`. Templated with `{{identity.entity.name}}`, which OpenBao substitutes per request.

---

## `helloworld-bff`

Source: [`infrastructure/openbao/policies/helloworld-bff.hcl`](../../infrastructure/openbao/policies/helloworld-bff.hcl)

```hcl
path "secret/data/apps/helloworld/+" {
  capabilities = ["read"]
}
path "secret/metadata/apps/helloworld/+" {
  capabilities = ["read", "list"]
}

path "database/creds/helloworld-app-readwrite" {
  capabilities = ["read"]
}

path "transit/encrypt/pii-encryption" {
  capabilities = ["update"]
}
path "transit/decrypt/pii-encryption" {
  capabilities = ["update"]
}
```

**Mapped to:**
- `auth/jwt/role/helloworld-bff` bound to `spiffe://secforge.local/ns/app/sa/helloworld-bff`
- `auth/jwt/role/authzen-facade` bound to `spiffe://secforge.local/ns/app/sa/authzen-facade` (for testing)

**Use:** the policy a Phase 9 BFF (or the AuthZEN façade test path) holds at runtime. Lets the workload:
- read static config from `secret/data/apps/helloworld/<key>`
- mint a fresh Postgres credential each hour
- encrypt + decrypt PII columns via Transit (without holding the key)

**Note on `+` glob:** OpenBao's `+` matches a single path segment. `secret/data/apps/helloworld/+` matches `secret/data/apps/helloworld/db-config` but not `secret/data/apps/helloworld/v1/db-config`. Use `*` in HCL paths for multi-segment wildcards.

---

## Adding a new policy

1. Author `infrastructure/openbao/policies/<name>.hcl`. Keep it minimal — list specific paths and capabilities, not `*`.
2. `bash infrastructure/openbao/load-policies.sh` (idempotent — overwrites by name).
3. Bind it to an auth role:
   - For workload-issued tokens: `bao write auth/jwt/role/<name> ... policies=<name> bound_subject=<spiffe-id>`
   - For human admins: extend `auth/oidc/role/<name>` similarly.
4. Update `docs/06-reference/openbao-policies.md` with what the policy grants and who's mapped to it.

---

## Capability cheat sheet

| Capability | What it permits |
|---|---|
| `create` | POST a new value at the path |
| `read` | GET the value |
| `update` | POST/PUT to overwrite an existing value |
| `delete` | DELETE the value |
| `list` | LIST keys under a prefix |
| `sudo` | bypass restrictions OpenBao reserves for root (rare; mostly for `sys/` paths) |
| `deny` | explicit deny — overrides any `allow` from another policy |

---

## Follow-ups

### #31 — `realm_access.roles` claim missing in OpenBao OIDC userinfo

During Phase 5 setup, the Keycloak `realm roles` mapper on the `roles` client scope was confirmed configured (Token Claim Name=`realm_access.roles`, Add to ID/access/userinfo all ON, `jason.upole` has `platform_admin` assigned). Yet OpenBao's `claim_mappings` captured only `kc_email` + `kc_username` from the OIDC alias metadata — not `kc_realm_roles`. To unblock, the OIDC `admin` role binds on `preferred_username=jason.upole` instead of the realm role.

**Resolution path:** capture the raw ID token from a fresh login (browser DevTools → Network → callback exchange → decode the JWT payload). Once we know whether the claim is missing entirely, in a different path, or in a different format, swap `bound_claims` back to `realm_access/roles=platform_admin` so additional Keycloak users with `platform_admin` automatically inherit the OpenBao admin policy.
