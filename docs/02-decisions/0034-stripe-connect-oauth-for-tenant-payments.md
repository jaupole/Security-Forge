# ADR-0034: Stripe Connect (OAuth, Standard accounts) for tenant payments — replaces bring-your-own-keys

**Status**: Accepted (strategy) — 2026-06-05. Implementation phased and **not yet built**; a Phase 0 docs-verification gates the *link mechanism* (OAuth-Standard vs Accounts v2), not the strategy.
**Date**: 2026-06-05
**Decision-makers**: Project owner (forks decided 2026-06-05 — fee-free; link existing accounts)

## Context

The platform has **two** distinct Stripe relationships:

1. **Platform billing** — Control's own Stripe account bills tenant orgs for using SecForge (`admin-billing.ts`, `webhooks-stripe-platform.ts`, the `billing.secforge.dev` platform webhook).
2. **Per-org tenant payments** — each org collects its own member/invoice payments on **its own** Stripe account.

This ADR concerns **#2 only**.

Today #2 is **bring-your-own-keys**: an org pastes a restricted key (`rk_…`) + webhook signing secret (`whsec_…`) into the Portal (`IntegrationsPage.tsx` StripeForm); Control stores them OpenBao-Transit-encrypted; Member Hub builds a per-org client (`new Stripe(cfg.secretKey)`, `payments/stripe.ts`) and creates Checkout Sessions directly on the org's account. The **org is merchant of record**; SecForge is **not in the money flow** and carries **zero Stripe liability** for tenant payments.

Costs of BYO-keys:
- Clunky onboarding + live/test mode ↔ key-prefix foot-guns.
- A per-tenant `rk_`/`whsec_` pair to store **and rotate** in OpenBao — adds to the per-tenant Transit-key rotation surface (open follow-up; see operator-backlog).
- A per-org webhook URL + signing secret (`billing.secforge.dev/member-hub/<orgId>`).

Goal: give Stripe the **same one-click OAuth connect UX the QBO integration has**, and **eliminate per-tenant Stripe secrets** — without changing who gets the money or who carries the risk.

## Decision

Adopt **Stripe Connect** for per-org tenant payments using **OAuth to link the org's existing Standard account** (the consent returns the org's `acct_…`), **direct charges** on the connected account (`{ stripeAccount: 'acct_…' }`), and **no `application_fee_amount`** (SecForge takes no cut). Store the connected `acct_…` in Control in place of the per-org keys; Member Hub uses **one platform key + the `Stripe-Account` header**; a single platform-level **Connect webhook** endpoint replaces the per-org URLs. Existing BYO-key orgs migrate via a **parallel run**, retiring the key columns + per-tenant secrets once cut over.

## Rationale (chose X over Y because Z)

- **Connect OAuth Standard over Accounts v2 hosted onboarding** — the owner's requirement is "orgs mostly already have their own Stripe accounts; let them link." OAuth-for-Standard is Stripe's path to authorize a platform onto an **existing** account; Stripe's own Accounts v2 doc states *"If your platform uses OAuth to authenticate with connected accounts, continue using the v1 APIs."* Accounts v2 targets platforms that **provision** accounts, which is not our case. This deliberately diverges from the `stripe-best-practices` skill's generic "always use Accounts v2 for new platforms" default — that default assumes provisioning; we are linking.
- **Standard account over Express/Custom** — the Connect security guidance: platforms bear fraud/dispute liability on Express/Custom; **Standard minimizes it** (Stripe manages risk; the connected account owns losses + disputes, pays Stripe fees, keeps its own full dashboard, stays merchant of record). This preserves today's liability split exactly.
- **Direct charges + no application fee over destination charges / fees** — owner chose fee-free. Direct charges keep funds settling to the org with SecForge never in the funds path; omitting `application_fee_amount` means no cut and no marketplace responsibility. **Economics identical to BYO-keys.**
- **Reuse** — this is the same OAuth-connect shape already built (and fixed, 2026-06-05) for QBO in Control: `routes/accounting-config.ts` (state CSRF cookie → provider consent → callback stores the id → redirect to the Portal). The Stripe connect/callback is a sibling, not a new pattern.

## Alternatives considered and rejected

- **Keep BYO-keys (status quo)** — zero new platform obligations, but keeps the onboarding friction, the per-tenant secret storage/rotation, and the per-org webhook plumbing. Rejected: that cost is precisely what we are removing.
- **Connect with application fees (marketplace)** — a per-transaction revenue lever, but makes SecForge a genuine marketplace with more platform responsibility + fee-disclosure obligations to orgs. Rejected by owner (fee-free).
- **Accounts v2 + hosted onboarding (provision new accounts)** — the skill's default. Rejected as the **primary** path because orgs already hold accounts; forcing new-account provisioning loses their history/payout config. Retained as the **fallback** if Phase 0 finds new OAuth-Standard platform registration is no longer offered (see Re-evaluation).
- **Express / Custom accounts** — rejected per the liability guidance.

## Consequences

- **Preserved:** org is merchant of record; org pays Stripe fees; org owns disputes/refunds/negative balances; SecForge takes no cut and is never in the funds flow. Today's economics + liability split are unchanged.
- **New obligation:** SecForge becomes a **registered Connect platform** (Connect profile + platform terms on the existing platform Stripe account). A platform/registration responsibility — **not** financial liability.
- **Removed:** per-tenant `rk_`/`whsec_` in OpenBao (one platform key + `Stripe-Account` header instead) — shrinks the per-tenant Transit-rotation surface. Per-org webhook URL+secret collapses to **one** platform Connect endpoint (events carry `account`, verified with one signing secret).
- **Code surface:** Control gains OAuth connect/callback routes + `acct_…` storage; Member Hub `getStripe()` branches connected-account vs legacy-key; the webhook receiver consolidates; the Portal swaps the key form for a "Connect with Stripe" button. Task breakdown in [`stripe-connect-migration-plan.md`](../06-reference/stripe-connect-migration-plan.md).
- **Migration risk:** existing orgs must re-authorize via one OAuth consent to bind their existing `acct_…`; parallel-run keeps BYO-keys working until each org is cut over.
- **Constraint to honor:** OAuth `read_write` (since June 2021) cannot link an account already **controlled by another platform** — a blocker only for an org whose account is already under a different platform.

## Re-evaluation criteria

- **Phase 0 verification gates the mechanism:** confirm against current Stripe docs that new platforms can still register and use OAuth-for-Standard. If Stripe has closed new OAuth-Standard registration, flip the mechanism to **Accounts v2 + hosted onboarding** — the strategy (Connect, fee-free, org-as-merchant-of-record, minimal liability) stands; only the link mechanism changes.
- Revisit the fee-free decision if SecForge later wants per-transaction revenue (adds `application_fee_amount` + marketplace obligations — a new ADR).
- Revisit if Stripe deprecates direct charges for Standard accounts or changes the Standard liability model.

## References

- `stripe-best-practices` skill: `references/connect.md`, `references/security.md`.
- Stripe docs: Accounts v2 (`/connect/accounts-v2`), Connect OAuth reference (`/connect/oauth-reference`), Connect charges (`/connect/charges`).
- In-repo prior art (the OAuth pattern this clones): `Ecosystem Control/src/api/routes/accounting-config.ts`; runbook `docs/03-runbooks/quickbooks-online-setup.md`.
- Current BYO-keys surface: `Member Hub/src/modules/payments/stripe.ts`; Control `routes/stripe-config.ts` + `system-stripe-config.ts`; Portal `IntegrationsPage.tsx` (StripeForm).
- Implementation plan: [`docs/06-reference/stripe-connect-migration-plan.md`](../06-reference/stripe-connect-migration-plan.md).
- Relates to [ADR-0013](./0013-outbound-secrets-no-env.md) (removes per-tenant outbound secrets) and [ADR-0018](./0018-multi-tenancy-rls-strategy.md) (per-org isolation).
