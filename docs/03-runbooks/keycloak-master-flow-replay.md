# Keycloak `master` realm flow replay (DR + drift fix)

> **TL;DR** — The `master` realm is the Keycloak bootstrap realm: it is **not**
> realm-importable and 03a's kcadm path cannot authenticate against it (the
> sole master admin is WebAuthn-required, so no headless kcadm session can be
> opened). Its login posture — **username+password first factor, passkey-
> preferred 2FA, recovery codes as break-glass** — therefore lives only in the
> live DB. `platform/components/03c-keycloak-master-passkey-2fa.sh` is the
> recovery path: it reproduces that posture from scratch via direct Postgres
> writes, idempotently, the same way 03b does for the `secforge-tenants` realm.

## Why master is special

| Realm | Declarative source | Day-2 / DR replay |
|-------|--------------------|-------------------|
| `platform` | `manifests/keycloak/realms/platform-realm.yaml` | 03a (kcadm) |
| `secforge-tenants` | `manifests/keycloak/realms/secforge-tenants-realm.yaml` | 03b (DB-write) |
| `master` | **none** (bootstrap realm, not importable) | **03c (DB-write)** ← this runbook |

Without 03c, a DB rebuild or a restore from a backup predating the manual
hardening brings master back on Keycloak's stock `browser` flow: password only,
no passkey, and recovery codes can resurface ahead of the passkey at the 2FA
step. 03c closes that gap.

## What 03c guarantees

- Custom `browser-webauthn-required` flow exists and is bound as the realm
  browser flow.
- `auth-username-password-form` is the REQUIRED first factor.
- In the conditional 2FA subflow, `webauthn-authenticator` is an ALTERNATIVE
  with a **lower priority number** than `auth-recovery-authn-code-form` — the
  **passkey-before-recovery invariant**. Keycloak 26 presents the first
  alternative configured for the user, so the passkey is the default second
  factor and recovery codes appear only via *"Try another way"*.
- Required actions: `webauthn-register` forced; `CONFIGURE_RECOVERY_AUTHN_CODES`
  **retained** (sole-admin break-glass); `CONFIGURE_TOTP` off.
- WebAuthn (2FA) policy: `RpId=secforge.dev`, UV required, ES256/RS256.

**Key contrast with 03b:** 03b *deletes* tenant recovery-codes credentials and
disables the recovery action (tenants recover via email reset + help-desk). 03c
does the opposite — master keeps recovery codes, and the script **never deletes
a credential**.

## When to run

- **After any master-realm DB rebuild / restore** (DR drill, migration) once
  `keycloak-0` is Running and the DB is reachable.
- **As a drift check** — `--check` is read-only and safe against the live admin
  realm at any time.

## How to run

`kubectl` is auto-detected (plain, else `sudo -n kubectl`), so no kubeconfig
prep is needed on the prod box.

```bash
cd /home/ops/secforge

# Read-only verification (safe on the live admin realm):
./platform/components/03c-keycloak-master-passkey-2fa.sh --check

# DR / drift repair (idempotent; rebinds browser_flow + bounces keycloak-0):
./platform/components/03c-keycloak-master-passkey-2fa.sh

# Apply without the pod bounce (flush Infinispan yourself afterwards):
./platform/components/03c-keycloak-master-passkey-2fa.sh --no-bounce
```

Exit codes: `0` in/brought-to target state · `1` pre-flight failure · `2`
verification mismatch (drift).

## Safety notes

- The apply path rebinds `realm.browser_flow` to the custom flow and bounces
  `keycloak-0` (direct DB writes do not invalidate the Infinispan flow cache).
  Do **not** run apply unless you intend to mutate the live admin login; use
  `--check` to inspect.
- Before relying on 03c for a real master recovery, confirm at least one usable
  passkey **and** a current set of recovery codes exist for the admin account —
  03c restores the *flow*, not your *credentials*.

## Related

- `platform/components/03b-keycloak-tenants-flexible-flow.sh` — sibling DB-write replay (tenants).
- `platform/components/03a-keycloak-realm-hardening.sh` — kcadm hardening (platform + tenants).
- `docs/03-runbooks/keycloak-realm-hardening-replay.md` — the kcadm replay runbook.
