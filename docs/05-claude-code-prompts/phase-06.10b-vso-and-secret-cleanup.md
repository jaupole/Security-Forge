# Phase 6.10b — VSO install + secret cutover cleanup

**Status:** ⬜ Not started

**Estimated time:** ~half day (6 steps, 2 destructive operations)

**Prerequisites:** Phase 6 through 6.10 complete. BFF deployed and reading
its `private_key_jwt` from OpenBao via SPIFFE-bound auth (Phase 6.6 / 6.8).
Phase 5.10 secrets replicated into OpenBao (`secret/data/spicedb/preshared-key`,
`secret/data/keycloak/clients/<id>`).

---

## Why this is its own phase doc

Originally inline in `phase-06-istio-bff.md` §6.10b as "cutover Phase 5.10
secrets." Grew to: install Vault Secrets Operator + cutover SpiceDB +
AuthZEN + refactor `bootstrap-bff-clients.sh` + cleanup. 6 steps,
2 destructive operations, an ADR (ADR-0015), a new platform component
(VSO), and a script refactor with a known bug to work around. That's a
phase, not a sub-step. Separate prompt doc keeps the working context clean
and gives ADR-0015 a stable reference target.

---

## Goal of this phase

Make OpenBao the sole source of truth for both the SpiceDB preshared key
and the four BFF `private_key_jwt` keypairs. Establish the asymmetric
distribution pattern documented in [ADR-0015](../02-decisions/0015-secret-distribution-pattern.md):
VSO for operator-owned and operator-shaped consumers (SpiceDB, AuthZEN
façade); direct-API via `apps/lib/secrets/` for first-class apps we
control end-to-end (BFF). Delete the now-redundant K8s Secret copies so
they cannot drift.

---

## The 6-step plan

### Step 1 — Write ADR-0015 stub *(done before this phase runs)*

ADR-0015 stub is created at `docs/02-decisions/0015-secret-distribution-pattern.md`
with `Status: In progress`. Title: "Secret distribution pattern (VSO +
direct-API)." This step is complete before Step 2 begins so the ADR slot
is reserved per CLAUDE.md ADR-numbering rules.

### Step 2 — Install Vault Secrets Operator (VSO)

Install VSO via Helm into a dedicated namespace (recommend
`vault-secrets-operator`). Configure it to authenticate to the in-cluster
OpenBao via Kubernetes auth mounted at the existing `auth/kubernetes/`
path, with a SPIFFE-aware policy scoped to read paths under
`secret/data/spicedb/*` and `secret/data/keycloak/clients/*`.

**Verify before proceeding:** VSO operator pod is `Running` and `Ready`,
and its logs show successful auth to OpenBao. Do NOT create
`VaultStaticSecret` resources for production consumers yet — that happens
in Step 3.

**Lessons surfaced during Step 2 (carry forward to Step 3):**

1. **VSO + restricted PSS.** The chart's defaults set only
   `runAsNonRoot` + `allowPrivilegeEscalation: false`. The
   `vault-secrets-operator` namespace's `pod-security.kubernetes.io/enforce: restricted`
   label requires `capabilities.drop=["ALL"]` and
   `seccompProfile.type=RuntimeDefault` as well. Override
   `controller.podSecurityContext` and `controller.securityContext`
   in `01-helm-values.yaml`. A Helm map override replaces the default
   wholesale — re-state the original keys alongside the new ones.

2. **VSO K8s auth is namespace-scoped.** VSO obtains its OpenBao login
   credential by calling K8s TokenRequest against
   `<consumer-ns>/<sa-name>`, where `<consumer-ns>` is the namespace of
   the `VaultStaticSecret` (NOT the `VaultAuth`'s namespace). The SA
   referenced by `VaultAuth.spec.kubernetes.serviceAccount` must
   therefore exist in EACH namespace where a VaultStaticSecret renders.
   This is by design (TokenRequest is namespace-scoped) and shapes
   Step 3 below.

3. **Stale Helm pre-delete hook.** If a Kyverno-blocked install fails
   partway, helm records the pre-fix template in its release history,
   and the next `helm uninstall` runs that stale Job through Kyverno
   again. Use `helm uninstall --no-hooks` to escape.

4. **CLI redirect URI gap (Phase 5.6 follow-up).** The OpenBao `admin`
   OIDC role's `allowed_redirect_uris` only lists UI callbacks
   (`https://bao.secforge.local/...`), not the bao CLI's local
   listener (`http://localhost:8250/oidc/callback`). Step 2 worked
   around this by getting the admin token via the UI and exporting
   `BAO_TOKEN` manually. Add a small fix to `configure-auth-oidc.sh` —
   tracked as a separate Phase 5.6 follow-up in PLAN.md.

### Step 3 — Refactor `bootstrap-bff-clients.sh` and create VaultStaticSecret resources

Two parallel pieces of work, bundled because they touch the same Phase 5.10
material:

**3a. `bootstrap-bff-clients.sh` refactor.** The script currently registers
the 4 BFF clients with Keycloak and writes their public keys, then writes
private keys to K8s Secrets. Refactor so the K8s-Secret-write step is
removed (private keys go to OpenBao only — they already do as of Phase 6.8;
this step removes the now-redundant write).

  - **Known bug to work around:** the script uses `kcadm --otp` for master-realm
    auth, which kcadm 26.x removed (see auto-memory `kcadm_26x_no_totp.md`,
    surfaced in Phase 6b-0). Do the **minimum** to unblock Step 3:
    switch the auth section to `client_credentials` via the existing
    `kcadm-spike` service-account client (`KCADM_CLIENT_SECRET` env var,
    same pattern the spike scripts use), or skip the auth section
    entirely if Step 3 doesn't need to run the script during 6.10b.
  - **Do NOT fold the kcadm-admin migration into 6.10b.** That migration
    is a Phase 3 follow-up tracked separately in PLAN.md. Goal here is
    "leave the script with a working auth path," not "do the full
    migration."

**3b. VaultStaticSecret resources.** Create `VaultStaticSecret` CRDs that
materialize K8s Secrets from OpenBao. Because VSO's K8s auth is
namespace-scoped (Step 2 lesson 2), each consumer namespace needs its
own SA + VaultAuth + OpenBao role binding. Plan:

**spicedb namespace:**
  - SA: `spicedb-vso` (new; `infrastructure/spicedb/01-serviceaccount.yaml`
    or a new file to keep VSO concerns separate).
  - VaultAuth in `spicedb` ns named `default`, referencing the
    cross-namespace VaultConnection
    `vault-secrets-operator/openbao` and the local `spicedb-vso` SA.
  - OpenBao K8s auth role `spicedb-vso` bound to `spicedb/spicedb-vso`
    SA, granting the existing `vso` policy (read on
    `secret/data/spicedb/preshared-key`).
  - VaultStaticSecret `spicedb-config-vso` in `spicedb` ns sourcing
    `secret/data/spicedb/preshared-key`, rendering K8s Secret
    `spicedb-config-vso` for the SpiceDB StatefulSet.

**app namespace (AuthZEN):**
  - Today AuthZEN consumes a separate K8s Secret
    `app/authzen-facade-spicedb-creds` (NOT the spicedb-ns
    `spicedb-config` — they're independent copies of the same preshared
    key, manually replicated). Step 3 must recognize this — there are
    TWO K8s Secrets to cut over, not one.
  - SA: `authzen-facade-vso` in `app` ns.
  - VaultAuth in `app` ns named `authzen-facade`, referencing
    `vault-secrets-operator/openbao` + the local SA.
  - OpenBao K8s auth role `authzen-facade-vso` bound to
    `app/authzen-facade-vso`, granting the `vso` policy.
  - VaultStaticSecret `authzen-facade-spicedb-creds-vso` in `app` ns
    sourcing the same `secret/data/spicedb/preshared-key`, rendering
    `authzen-facade-spicedb-creds-vso`.

**Refresh interval**: start with VSO default (60s) for both; revisit
in ADR-0015's "open questions" if rotation cadence demands tighter.

Cut SpiceDB over to consume `spicedb-config-vso`. Roll the SpiceDB pod.
Cut AuthZEN over to consume `authzen-facade-spicedb-creds-vso`. Roll
the AuthZEN Deployment. Verify CheckPermission calls still succeed
using `infrastructure/spicedb/check-permissions.sh` and that AuthZEN
still answers requests.

**Verify before proceeding:** SpiceDB and AuthZEN have been running on
`spicedb-config-vso` for **≥10 minutes** with successful CheckPermission
calls and no restart loops. The 10-minute soak catches VSO refresh-cycle
bugs that don't surface immediately.

### Step 4 — Delete the original SpiceDB+AuthZEN K8s Secrets *(destructive, higher-risk)*

```bash
kubectl delete secret spicedb-config -n spicedb
kubectl delete secret authzen-facade-spicedb-creds -n app
```

Watch SpiceDB and AuthZEN for ≥5 minutes after deletion. The
`spicedb-config-vso` Secret (in spicedb ns) and
`authzen-facade-spicedb-creds-vso` Secret (in app ns), both managed by
VSO, replace the originals; the original Secrets are now orphans.

**Why this is Step 4 and not Step 5:** SpiceDB cutover is the higher-risk
of the two destructive operations — operator-managed StatefulSet, two
consumers in two different namespaces (SpiceDB in spicedb ns + AuthZEN
in app ns), schema-owning workload. BFF cutover (Step 5) is essentially
already done per Phase 6.8 — the BFF Secrets are orphans. Verify the
higher-risk cutover before touching the lower-risk one. Fewer concurrent
unknowns if something goes wrong.

**Rollback:** if SpiceDB or AuthZEN start failing, recreate the original
Secrets from the values in `secret/data/spicedb/preshared-key` (read via
`kubectl exec` into the openbao pod), and roll both workloads back to
their original `secretRef`. Investigate before retrying.

### Step 5 — Delete BFF `bff-jwt-*` K8s Secrets *(destructive, lower-risk)*

```bash
kubectl delete secret bff-jwt-helloworld-bff bff-jwt-proposal-forge-bff \
  bff-jwt-project-tracker-bff bff-jwt-pm-bff -n app
```

Restart the BFF (`kubectl rollout restart deployment/helloworld-bff -n app`).
Verify it boots cleanly from OpenBao only:

- BFF pod reaches `Ready` and logs show successful OpenBao read of
  `secret/data/keycloak/clients/helloworld-bff`.
- `/healthz` returns 200.
- `/login` issues correct PAR redirect to Keycloak (same check as the
  Phase 6.9 partial verification).

**Rollback:** same pattern as Step 4 — recreate the K8s Secret from
OpenBao if needed, investigate before retrying.

### Step 6 — Update ADR-0015, PLAN.md, and CLAUDE.md

- Fill in ADR-0015 content based on what actually happened (refresh-interval
  decisions, AuthZEN's `VaultStaticSecret` choice, any failure modes that
  surfaced). Resolve the open questions or carry them forward as known
  limitations. Mark `Status: Accepted`.
- Update PLAN.md Phase 5 entry: remove the "K8s Secrets stay authoritative"
  note (line ~211); replace with "Cutover completed in Phase 6.10b —
  OpenBao is sole source of truth."
- Update PLAN.md Phase 6 entry: mark 6.10b ✅ with date.
- Update CLAUDE.md architecture stack table: confirm the "Outbound Secret
  Sync" row references ADR-0015. (Stub-creation step should have already
  added this row; Step 6 confirms it points at the now-Accepted ADR.)

---

## Operational hand-offs documented elsewhere

Three explicit hand-offs from this phase, all captured in
[ADR-0015 §"Operational hand-offs to other phases"](../02-decisions/0015-secret-distribution-pattern.md):

- **Phase 7 — BFF `private_key_jwt` rotation.** This phase moves BFF
  private keys into OpenBao but does NOT implement rotation. ~half day,
  scheduled for Phase 7 alongside the kcadm-admin migration.
- **Phase 3 — `kcadm-admin` migration.** Step 3a does the minimum to make
  `bootstrap-bff-clients.sh` work; the full migration is a Phase 3
  follow-up, not folded in here.
- **OpenBao audit log reuse (Phase 7 observability).** Both VSO-mediated
  and direct-API reads appear in the OpenBao audit log with their SPIFFE
  IDs. Phase 7 should treat the audit log as single source of truth for
  "who read which secret when," regardless of distribution path.

---

## Why this matters

Leaving two copies of the same secret is a drift trap. The first time
someone rotates one and forgets the other, debugging is painful. Finish
the migration in this phase, not "someday." The asymmetric pattern
(VSO + direct-API) is the right architectural shape — see ADR-0015 — but
"right shape" without finishing the cutover means the K8s Secrets keep
existing as a quiet alternate truth.

---

## See also

- [ADR-0015 — Secret distribution pattern (VSO + direct-API)](../02-decisions/0015-secret-distribution-pattern.md)
- [ADR-0013 — Outbound secrets: no env vars](../02-decisions/0013-outbound-secrets-no-env.md)
- [Phase 6 prompt — Service Mesh and BFF](./phase-06-istio-bff.md) (this
  phase was originally inline at §6.10b)
- Auto-memory: `kcadm_26x_no_totp.md`, `host_bao_cli_missing.md`
