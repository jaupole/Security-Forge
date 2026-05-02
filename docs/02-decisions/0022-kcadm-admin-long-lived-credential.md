# ADR-0022: `kcadm-admin` long-lived service-account credential

**Status**: Accepted
**Date**: 2026-05-01
**Decision-makers**: Project owner

## Context

Every Keycloak administrative script in `infrastructure/keycloak/` authenticates via `kcadm.sh config credentials` against the master realm. Today those scripts use a master-realm user (`jaupole`) with password+TOTP-concat — a workaround pattern where the master realm's direct-grant flow accepts the trailing 6 OTP digits of the password field. Two problems:

1. **kcadm 26.x dropped the `--otp` flag.** `infrastructure/keycloak/verify.sh` lines 38-49 still use `OTP_FLAG=(--otp "$KCADM_TOTP")`. Phase 3's automated re-verification harness no longer runs.
2. **The password+TOTP-concat trick is fragile.** It depends on the master realm's direct-grant flow accepting trailing OTP digits, which is version-dependent. It surfaced as a hard failure during Phase 6b-0 (the token-exchange spike), where the operator had to manually create a `kcadm-spike` service-account client to get the spike unblocked.

Every future kcadm-driven script (and we have four of them today: `verify.sh`, `clients/openbao.sh`, `realms/bootstrap-bff-clients.sh`, `realms/create-tenant-test-user.sh`) will hit this wall. The answer is to stop authenticating as a human user and start authenticating as a Keycloak **service-account client** with `client_credentials` flow.

This ADR documents:

- the rationale for using a long-lived (>24h) credential despite [CLAUDE.md's "Things that should NEVER happen" rule against long-lived credentials](../../CLAUDE.md);
- the role scope, custody model, rotation cadence, and audit-trail strategy for the `kcadm-admin` client;
- the decision between two host-side OpenBao access paths (operator's WSL-host `bao` CLI vs. `kubectl exec` into the OpenBao pod) for the migration scripts that fetch the client secret.

## Decision

**Provision a long-lived `kcadm-admin` confidential client in Keycloak's `master` realm with the service-account flow only. Store its `client_secret` in OpenBao at `secret/data/keycloak/clients/kcadm-admin`. Rotate the secret every 90 days (precedent: realm signing keys per [ADR-0006](./0006-keycloak-keys-local.md)). Migrate every kcadm-using script to fetch the secret from OpenBao and authenticate via `kcadm config credentials --client kcadm-admin --secret <fetched>`.**

Specifically:

| Property | Value |
|---|---|
| Realm | `master` (kcadm authenticates against master regardless of the realm it operates on) |
| Client ID | `kcadm-admin` |
| Auth method | `client-secret` (service-account flow) |
| Standard / direct-grant / implicit / device flows | **disabled** |
| Service-accounts enabled | **true** |
| Public client | **false** (confidential) |
| Refresh tokens | unused (kcadm acquires a fresh access token per `config credentials` invocation) |
| Audit | every `client_credentials` exchange produces a Keycloak event ([§Audit-trail strategy](#audit-trail-strategy)) |
| OpenBao path | `secret/data/keycloak/clients/kcadm-admin` |
| Rotation cadence | 90 days; tracked in [`docs/03-runbooks/keycloak-operations.md` § Rotate kcadm-admin client secret](../03-runbooks/keycloak-operations.md) |
| Host-side access path | option (b) — `kubectl exec` into the openbao pod (see [§Host-side access path](#host-side-access-path)) |

Service-account roles granted on the kcadm-admin client (the union needed across all four migrated scripts):

| Realm-management client | Roles | Granted because |
|---|---|---|
| `master-realm` | none | kcadm-admin operates on `platform` and `secforge-tenants`, not `master` itself |
| `platform-realm` | `manage-clients`, `manage-realm`, `manage-users`, `view-realm` | `clients/openbao.sh` creates/updates the openbao client + creates the `platform_admin` realm role + assigns it to a user |
| `secforge-tenants-realm` | `manage-clients`, `manage-users`, `view-realm`, `view-authorization`, `view-events` | `bootstrap-bff-clients.sh` creates/updates 4 BFF clients; `create-tenant-test-user.sh` creates/updates tenant users + sets passwords; `verify.sh` reads client configs + required-actions + events |

The role list is a **union of declared needs**, not a "manage-all" grant. CLAUDE.md's "no SA cluster-admin" principle generalizes — kcadm-admin gets exactly the roles its declared scripts need, no more.

Adding a new kcadm script that needs a role outside this list is a **two-step operator workflow**:

1. Append the new role to the "Roles granted" table above (this ADR is amended in place — append-only with a "Roles added YYYY-MM-DD" note).
2. Re-run `infrastructure/keycloak/clients/kcadm-admin.sh` (idempotent) to grant the new role.

This is the same discipline as adding a new audience to `BFF_AUDIENCE_LIST` (Q2 of [ADR-0014](./0014-api-auth-library-design.md)) — the role list is committed config, runtime cannot bypass.

## Rationale

### Why long-lived (and why CLAUDE.md grants the carve-out)

CLAUDE.md "Things that should NEVER happen" forbids "Generating long-lived (>24h) credentials of any kind, except where the architecture document explicitly approves it (e.g., realm signing keys with 90-day rotation)." The carve-out language uses realm signing keys as the **archetype** of an acceptable long-lived credential — a credential that:

1. Cannot itself be made short-lived without breaking the operational model (realm signing keys must stay valid until existing tokens expire; kcadm-admin must stay valid across script runs without prompting an operator for fresh credentials).
2. Carries a documented rotation cadence with overlap windows for clean cutover.
3. Has a custody model that makes blast-radius bounded (limited role grants; OpenBao-stored; rotation-able without manual intervention).

`kcadm-admin` meets all three. The alternatives are worse:

- **Per-script user credentials with TOTP** is broken on kcadm 26.x. The `--otp` flag is gone; password+TOTP-concat depends on direct-grant-flow OTP-handling that's version-dependent.
- **Service-account-keystore (private_key_jwt)** auth would let us avoid storing a long-lived secret at the cost of running a per-rotation key-management workflow. For local edition's four scripts, the implementation cost is not justified — and the key would itself be a long-lived credential, just with a different shape. Cloud-edition migration may revisit this when an HSM is available.
- **Skip kcadm and call Keycloak's REST API directly** would require re-implementing kcadm's update-with-merge, retry logic, and config-credentials caching. Trades one well-established tool for hand-rolled HTTP — clearly worse.

### Why 90-day rotation (and why not shorter)

90 days follows the realm-signing-key precedent in [ADR-0006](./0006-keycloak-keys-local.md). The cadence balances:

- **Operational muscle memory**: a credential that is never rotated is one whose rotation procedure has never been tested. 90 days is short enough that the operator runs the procedure ~4× a year — frequent enough to keep the runbook honest, infrequent enough not to be a chore.
- **Blast-radius reduction**: a leaked secret is valid for at most 90 days. For a service-account credential restricted to non-cluster-admin roles in a single Keycloak realm, the 90-day window is acceptable.
- **Cloud-edition handoff**: when this platform migrates to a managed Keycloak (Cognito, Auth0) per [`docs/06-reference/migration-keycloak-to-cognito.md`](../06-reference/migration-keycloak-to-cognito.md), this credential disappears (replaced by the cloud provider's native admin-API auth). The 90-day cadence won't be load-bearing forever.

Shorter rotation (e.g., 30 days) would be operationally heavier than the local-edition single-operator threat model warrants. Longer rotation (180+ days) drifts past industry best-practice for non-HSM-backed shared secrets.

### Audit-trail strategy

Every `kcadm config credentials --client kcadm-admin --secret …` exchange produces a Keycloak `LOGIN` admin event with `clientId=kcadm-admin`. Phase 7 ingestion (Loki + future Wazuh per Phase 7d) surfaces these events with the calling script's identity:

- The fact that **kcadm-admin authenticated** is observable via Keycloak's admin event log.
- The **calling script** is captured by Wazuh/Loki at the kubectl-exec layer (the script tag is the calling shell's process name + git ref).
- Every kcadm operation kcadm-admin performs (create-client, update-realm-role, set-password, etc.) emits its own admin event.

This means the audit trail says: "On 2026-MM-DD HH:MM, the script `infrastructure/keycloak/realms/create-tenant-test-user.sh` (commit `<sha>`) authenticated as `kcadm-admin` and created user `jason.upole` with required-actions `[UPDATE_PASSWORD, CONFIGURE_TOTP]`." That's enough to reconstruct what happened post-incident.

Per [§4 X-R1](../04-security/threat-model.md#4-cross-cutting-threats) of the threat model, audit-log integrity is an Accepted residual at local-edition scope (no tamper-evident chain). kcadm-admin's audit trail inherits that posture; cloud-edition picks it up under FedRAMP Moderate AU-3 / AU-9.

### Host-side access path

The migration scripts must fetch `kcadm-admin`'s client_secret from OpenBao before invoking `kcadm config credentials`. Two host-side access paths were evaluated:

#### Option (a) — `bao` CLI on the WSL host

`bao` 2.5.3 is installed at `~/.local/bin` (per Phase 6.10b Step 2 operator memory). It supports `bao read secret/data/keycloak/clients/kcadm-admin`. Authentication options for the `bao` CLI:

- **OIDC** (`bao login -method=oidc role=admin`) — currently broken per [F-CLU-11](../../Fix%20after%2007/00-audit-findings.md#f-clu-11--high--openbao-authoidcroleadmin-degraded--both-cli-and-web-ui-lock-out-post-fix-after-07-discovery-2026-05-01) (the OIDC role configuration is degraded — Web UI returns "Invalid role", CLI returns "redirect_uri not authorized"). F-CLU-11 doesn't block this ADR, but constrains option (a)'s auth choice.
- **Token** (`BAO_TOKEN=<root-or-admin-token> bao read …`) — works if the operator holds an admin-policy token from the bootstrap path. The token itself is long-lived → contradicts the spirit of the rotation discipline.
- **AppRole** (`bao write auth/approle/login role_id=… secret_id=…`) — would require setting up AppRole + a new credential to fetch another credential. Adds a layer.

#### Option (b) — `kubectl exec` into the OpenBao pod

Mirror the existing pattern in `infrastructure/openbao/configure-auth-oidc.sh` and `infrastructure/openbao/configure-engines.sh`: a wrapper function that invokes `bao` inside the `openbao-0` pod via `kubectl exec`, with `BAO_TOKEN` injected as an env var. The token comes from one of:

- The pod's mounted service-account JWT-SVID + a JWT-auth role with read-only access to `secret/data/keycloak/clients/kcadm-admin` (no host-side credential at all — the access path bootstraps from kubelet's pod-identity).
- A short-lived token minted by `bao token create -policy=kcadm-admin-reader -ttl=5m` invoked once at the start of each migration script, scoped to read-only access to the single KV path.

Option (b) wins for these reasons:

1. **Pattern consistency.** Every existing OpenBao infrastructure script uses the kubectl-exec wrapper. Adding a host-side `bao`-CLI path would create two patterns where one suffices.
2. **No host-tool prerequisite drift.** Operator-laptop tooling is already a known-fragile axis (operator memory notes friction with `kcadm` 26.x, `bao` 2.5.x; cluster-side keeps changing). Keeping kcadm migration on the kubectl-exec rail decouples it from host-tool versions.
3. **F-CLU-11 doesn't constrain the auth method.** The kubectl-exec path uses the openbao pod's already-authenticated context; we don't depend on host-side `bao login`.
4. **Auditability.** A kubectl-exec invocation appears in the K8s audit log with the operator's kubeconfig user. A host-side `bao read` is invisible to the cluster audit chain.

The latency overhead of kubectl-exec (~1-2s per invocation) is negligible for kcadm-provisioning scripts that aren't on a hot path.

## Alternatives considered and rejected

### Just leave the password+TOTP-concat pattern in place

Rejected. It's already broken on kcadm 26.x; `verify.sh` is currently inoperable. Even if we fixed verify.sh, the pattern is version-dependent and re-breaks every Keycloak upgrade. Better to migrate now to a stable mechanism.

### Per-script throwaway clients tagged `secforge.local/temporary=yes`

This is the **kcadm Path A pattern** the operator established during Phase 6b-0 — clone `spike-token-exchange.sh`'s service-account auth, create a fresh throwaway client per task, tear it down after. Path A is appropriate for ad-hoc spikes (where the client is genuinely temporary), but it is unsuitable as the steady-state pattern because:

- Bootstrapping the throwaway requires kcadm-admin (or equivalent) auth — the chicken-and-egg problem we're solving.
- The "tag and tear down" discipline depends on the operator remembering to clean up. Drift accumulates.
- Audit trails fragment across many short-lived client identities.

Path A continues to be useful for one-off migrations and spikes; it does not replace this ADR's steady-state kcadm-admin pattern.

### Move all kcadm operations into a Keycloak Operator-driven CRD reconciliation

The Keycloak Operator does provide CRDs for clients (`KeycloakClient`), realms (`KeycloakRealmImport`), roles, and users — and that *is* the cloud-edition direction. For the local edition we deliberately keep imperative kcadm scripts because:

- The operator's CRDs don't cover every operation kcadm does (e.g., `set-password --temporary`, runtime role-mapping inspection for verify.sh).
- The operator-CRD reconciliation cycle adds delay; for one-shot provisioning scripts that's pure overhead.
- A future cloud-edition migration that adopts CRD-driven everything will deprecate kcadm-admin alongside the imperative scripts. This ADR's reversal trigger ([§Reversal trigger](#reversal-trigger)) explicitly contemplates that handoff.

### Use Keycloak's `client_credentials` grant with `private_key_jwt` instead of `client_secret`

Considered. private_key_jwt is structurally stronger (the client never sends a shared secret over the wire) and matches the BFF clients' authn pattern. Rejected for kcadm-admin specifically because:

- The four migration scripts run from the operator's WSL host or CI; private_key_jwt requires the script to mint a fresh JWS per call, which `kcadm config credentials` does not natively support (no `--client-jwt-key` flag in 26.x).
- `kcadm config credentials --client … --secret …` is the documented and well-tested mechanism. Going off-rail to support private_key_jwt would mean rewriting the auth shim per script.
- The shared-secret blast-radius is bounded by the role-grant scope above and by the 90-day rotation. Cloud-edition's managed Keycloak (or equivalent) replaces this with provider-native admin-API auth.

If a future Phase needs private_key_jwt for admin operations (e.g. pre-cloud-migration hardening), this ADR is amended or superseded — not silently extended.

## Consequences

### What this commits us to

- A `kcadm-admin` client exists in Keycloak's master realm with the role grants enumerated above, provisioned by `infrastructure/keycloak/clients/kcadm-admin.sh` (idempotent).
- The client_secret lives in OpenBao at `secret/data/keycloak/clients/kcadm-admin`. Every migration script reads it via the kubectl-exec wrapper into `openbao-0`.
- Four migration scripts (`clients/openbao.sh`, `realms/bootstrap-bff-clients.sh`, `realms/create-tenant-test-user.sh`, `verify.sh`) authenticate via `--client kcadm-admin --secret <fetched>` instead of `KCADM_USER`/`KCADM_PASSWORD`/`KCADM_TOTP`.
- The `KCADM_USER` / `KCADM_PASSWORD` / `KCADM_TOTP` env-var pattern is removed across the repo (CI configs, helper scripts, `.env.example` files, README snippets).
- Rotation runbook in [`docs/03-runbooks/keycloak-operations.md`](../03-runbooks/keycloak-operations.md) covers the 90-day cadence (read OpenBao, rotate Keycloak client secret, write back to OpenBao, smoke-test a representative script).

### What this does NOT change

- Realm-level config (signing keys, required actions, client scopes) is unchanged. kcadm-admin only changes **how** scripts authenticate, not what they do.
- The Keycloak Operator and the realm CR shape stay identical to cloud. Migration to a managed Keycloak deletes kcadm-admin entirely; nothing else is affected.
- BFF clients, OpenBao OIDC client, AuthZEN-facade are untouched. This ADR concerns **administrative-tooling auth only**.

### Bootstrap caveat

The very first creation of `kcadm-admin` is a chicken-and-egg case: the provisioning script *needs* kcadm-admin to authenticate, but the client doesn't exist yet. The first invocation is therefore a **manual UI step by the operator**:

1. Operator opens the master-realm admin console, manually creates the `kcadm-admin` client (with the config in `infrastructure/keycloak/clients/kcadm-admin.sh`'s declared client representation).
2. Operator copies the generated `client_secret` and writes it into OpenBao at `secret/data/keycloak/clients/kcadm-admin` via `kubectl exec -n openbao openbao-0 -- env BAO_TOKEN=$ROOT_TOKEN bao kv put secret/keycloak/clients/kcadm-admin client_secret=…`.
3. From that point on, `infrastructure/keycloak/clients/kcadm-admin.sh` (idempotent) manages the client + the role grants + rotation.

The bootstrap caveat is documented in the provisioning script's header comment so operators know what to do on a fresh install.

## Reversal trigger

This ADR is reversed (i.e., the kcadm-admin client is deleted and its scripts migrate to a different auth mechanism) when **any** of:

1. A managed Keycloak (Cognito, Auth0, etc.) replaces the local Keycloak instance — the migration playbook deletes kcadm-admin and uses the cloud provider's native admin-API auth.
2. A future Keycloak version restores `--otp` or equivalent kcadm CLI support that lets per-user TOTP-bound auth work cleanly. (Unlikely; kcadm has been moving away from human-bound auth since 22.x.)
3. The platform adopts Keycloak Operator CRD-driven reconciliation for client / realm / user lifecycle, deprecating the four imperative scripts.
4. A security review surfaces a real exploitation path that the role-scope + 90-day-rotation discipline does not contain (e.g. lateral movement from kcadm-admin to a higher-privilege realm role we missed).

In any of those cases, the reversal procedure:

1. Migrate any remaining script consumers to the new mechanism.
2. Delete kcadm-admin from Keycloak's master realm.
3. Delete `secret/data/keycloak/clients/kcadm-admin` from OpenBao.
4. Mark this ADR `Status: Superseded by ADR-NNNN`.

## References

- [PLAN.md § "Phase 3 follow-up — kcadm-admin service-account pattern"](../../PLAN.md) — phase tracker.
- [F-CLU-11](../../Fix%20after%2007/00-audit-findings.md#f-clu-11--high--openbao-authoidcroleadmin-degraded--both-cli-and-web-ui-lock-out-post-fix-after-07-discovery-2026-05-01) — OpenBao OIDC role degradation that constrains option (a) of the host-side access path.
- [ADR-0006](./0006-keycloak-keys-local.md) — realm signing keys (precedent for long-lived credential + 90-day rotation).
- [ADR-0021](./0021-git-initialization-and-commit-signing.md) — commit-signing discipline (the audit trail backs admin-driven changes).
- [`docs/03-runbooks/keycloak-operations.md`](../03-runbooks/keycloak-operations.md) — runbook hosting the rotation procedure.
- [`infrastructure/keycloak/clients/kcadm-admin.sh`](../../infrastructure/keycloak/clients/kcadm-admin.sh) — provisioning script.
- Keycloak admin events: <https://www.keycloak.org/docs/latest/server_admin/index.html#admin-events>
