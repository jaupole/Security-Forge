# Stripe Connect migration plan

Implementation companion to [ADR-0034](../02-decisions/0034-stripe-connect-oauth-for-tenant-payments.md).
Migrates per-org tenant payments from bring-your-own-keys to **Stripe Connect
(OAuth, Standard accounts, direct charges, no application fee)**.

Spans three repos: **Ecosystem Control** (owns the connection + OAuth flow),
**Member Hub** (creates charges, receives webhooks), **Ecosystem Portal** (the
org-admin connect UI). Pattern to clone throughout: the QBO OAuth connect in
`Ecosystem Control/src/api/routes/accounting-config.ts`.

Guiding invariant: **at no point does an org's ability to take payments break.**
BYO-keys and Connect run in parallel until each org is individually cut over.

---

## Status — 2026-06-05

**All three phases are CODE-COMPLETE and pushed.** Parallel-run with BYO-keys;
nothing is live until deployed.

- **Phase 1 (Control)** ✅ ecosystem-control `8207649` — OAuth connect/callback,
  migration 065, system endpoint. Image rebuilt + digest bumped. Deploy wiring
  (env + `stripe-connect` Istio VS) in Security-Forge `b787a05`.
- **Phase 2 (Member Hub)** ✅ member-hub `d4632a8` — `getStripeForOrg` charge
  branch (platform key + Stripe-Account) + single `/api/webhooks/stripe/connect`.
- **Phase 3 (Portal + Control)** ✅ ecosystem-control `7a07619` +
  ecosystem-portal `82ad6c5` — "Connect With Stripe" UI + status-endpoint fields.

**Phase 0 finding:** OAuth-for-Standard is available (Stripe soft-discourages
but has not closed it) — mechanism stands.

**Remaining before a sandbox end-to-end test:**
1. Operator provisioning (browser/OpenBao): create the restricted platform key;
   write `platform_key` + `connect_webhook_secret` to
   `secret/apps/member-hub/stripe-connect`; register the Connect webhook
   (`members.secforge.dev/api/webhooks/stripe/connect`).
2. Deploy wiring: member-hub Deployment env (`STRIPE_PLATFORM_SECRET_KEY` +
   `STRIPE_CONNECT_WEBHOOK_SECRET` via VSO + ADR-0013 escape-hatch annotation)
   + VSO binding for `apps/member-hub/stripe-connect`.
3. Build the member-hub image; deploy Control + Member Hub + the Portal/admin
   image.
4. Sandbox test: connect a test org → checkout → Connect webhook → invoice paid
   → QBO sync.

**Deferred follow-up:** operator-adjustable "Ecosystem Stripe Connect App" card
(swap test→live `client_id` without a redeploy). Env-swap covers go-live in the
meantime.

---

## Phase 0 — Verify + register (no code)

Gates the mechanism (ADR-0034 Re-evaluation). Do this first; it can change Phase 1.

- [ ] **Confirm OAuth-for-Standard is still open to new platforms.** Read the
      current Stripe Connect OAuth docs. If new OAuth-Standard registration is
      closed, STOP and switch the plan to Accounts v2 + hosted onboarding (the
      strategy is unchanged; only the link mechanism + Phase 1 routes change).
- [ ] **Register the Connect platform** on the existing platform Stripe account:
      complete the Connect profile, accept platform terms, set branding
      (the org sees it on the consent screen), and capture the platform
      `client_id` (`ca_…`).
- [ ] Decide the **redirect URI host**. Reuse the QBO pattern: a dedicated public
      host (e.g. `stripe-connect.secforge.dev/callback`) routed by an Istio
      `VirtualService` to Control's internal callback route — the admin Portal
      origin is tailnet-only and Stripe can't reach it (this is the exact bug
      class fixed for QBO on 2026-06-05; `control.secforge.dev` is tailnet-only).
- [ ] Write the platform `client_id` + the Connect **webhook signing secret** to
      OpenBao (`secret/apps/control/stripe-connect`); surface via VSO like the
      QBO secrets. **No** per-tenant secrets — that is the whole point.

**Open question:** confirm whether direct charges on a Standard connected account
require the platform to also hold a `card_payments`/`transfers` capability grant,
or whether Standard accounts carry it implicitly. Resolve before Phase 2.

---

## Phase 1 — Control: the connection + OAuth flow

Clone `accounting-config.ts`. New module e.g. `routes/stripe-connect.ts`.

- [ ] **Schema:** add to the per-org Stripe config table:
      `stripe_connected_account_id TEXT NULL` (`acct_…`) and a
      `stripe_connection_mode` discriminator (`'oauth' | 'keys'`, default `keys`).
      Keep the existing key columns — they are the parallel-run fallback.
- [ ] **`POST /api/v1/orgs/:id/stripe/connect`** (admin-gated, mirrors the QBO
      connect): mint a Transit-encrypted `state` cookie `{orgId, sub, nonce, exp}`
      scoped to the callback path + parent domain; return the Stripe authorize
      URL (`https://connect.stripe.com/oauth/authorize?response_type=code&client_id=ca_…&scope=read_write&state=<nonce>`).
- [ ] **`GET /stripe/callback`** (public, mirrors the QBO callback): clear+decrypt
      the state cookie, verify `exp` + `nonce` equality + initiator still
      `organization.administer`, exchange `code` at `POST /v1/oauth/token` for the
      connected account's `stripe_user_id` (`acct_…`), store it + set
      `stripe_connection_mode='oauth'`, audit, then redirect to
      **`${PORTAL_ORIGIN}/admin/integrations?stripe=connected`** (note: now
      `portal.secforge.dev`, post-2026-06-05 fix).
- [ ] **Disconnect:** `POST /v1/oauth/deauthorize` (platform `client_id` +
      `stripe_user_id`), clear the stored `acct_…`, audit.
- [ ] **System endpoint** (`system-stripe-config.ts`): return the `acct_…` + mode
      to Member Hub instead of (or alongside) the legacy secret key.

Acceptance: an org admin clicks Connect → Stripe consent → lands back on the
Portal integrations page connected; the row carries an `acct_…`; no key was typed.

---

## Phase 2 — Member Hub: charge on behalf of the account

- [ ] **`getStripe()` branch** (`payments/stripe.ts`): when the org's mode is
      `oauth`, construct a SINGLE platform-key client and pass
      `{ stripeAccount: acct_… }` on every call (Checkout session create, tax
      rate create, etc.). When mode is `keys`, keep today's per-org-key client.
      The `stripeAccount` is request-scoped, so cache the platform client once,
      not per org.
- [ ] **Direct charges:** confirm Checkout session params are unchanged except for
      the `stripeAccount` header — no `transfer_data`, no `application_fee_amount`
      (fee-free). The connected account is merchant of record.
- [ ] **Webhooks consolidation** (`payments/webhook-routes.ts`): a single
      **Connect** endpoint verified with the ONE platform Connect signing secret.
      Events carry `account: acct_…`; map that back to the org via the stored
      `acct_…`. Retire the per-org `billing.secforge.dev/member-hub/<orgId>` +
      per-org `whsec_` once all orgs are on `oauth`.
- [ ] **TaxRate cache** (`getOrCreateTaxRateId`): TaxRate objects are created on
      the connected account (via `stripeAccount`); the per-(org,rate,label) cache
      key already scopes correctly — verify the cached IDs are account-scoped.

Acceptance (sandbox): a Checkout on a Connect-linked org pays the connected
account; the Connect webhook fires once, resolves to the right org, and the
invoice/payment outbox marks paid + syncs to QBO as today.

---

## Phase 3 — Portal UI + cutover + retire keys

- [ ] **Portal `IntegrationsPage.tsx`:** when the org is unconnected or on `keys`,
      show a **"Connect with Stripe"** button (mirrors the QBO `connectQbo` →
      `window.location.href = authorizeUrl` flow). When on `oauth`, show
      connected status (`acct_…`, live/test) + Disconnect. Keep the legacy key
      form reachable only as a fallback during migration, clearly deprecated.
- [ ] **Return banner:** handle `?stripe=connected|denied|error` (clone
      `QboReturnBanner`).
- [ ] **Migrate existing orgs:** each connects once via OAuth (binds their
      existing `acct_…`); their history/payouts are untouched. Track per-org
      cutover.
- [ ] **Retire BYO-keys:** once every active org is `oauth`, remove the key form,
      drop the legacy key columns, delete the per-tenant `rk_`/`whsec_` from
      OpenBao, and remove the per-org webhook ingress. Update the API security
      tracker.

Acceptance: zero orgs on `keys`; no per-tenant Stripe secrets remain in OpenBao;
one Connect webhook endpoint serves all orgs.

---

## Rollback

Connect is additive until Phase 3 retirement. To revert at any point before that:
stop offering the Connect button, set affected orgs back to `stripe_connection_mode='keys'`,
and they continue on their stored keys. The key columns + per-org webhooks are the
safety net and MUST NOT be dropped until Phase 3's "zero orgs on keys" gate passes.

## Security checklist (per ADR-0034 + the Connect security reference)

- OAuth `state`: unguessable per-request nonce, Transit-encrypted cookie,
  single-use, short TTL, re-checked for `organization.administer` at callback
  (identical to the QBO flow).
- Webhook signatures verified with the platform Connect signing secret; allowlist
  Stripe IPs at the ingress (defense in depth).
- Platform key is a restricted key with the minimum Connect scopes; stored in
  OpenBao, never logged. No per-tenant secrets after Phase 3.
- Honor the June-2021 OAuth `read_write` constraint (cannot link an account
  already controlled by another platform) — surface a clear error if a link is
  rejected for that reason.
