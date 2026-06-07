# Reference Documents

Long-form reference material and the live trackers that support day-to-day operations.

## Trackers (keep current)

- [`operator-backlog.md`](./operator-backlog.md) — open follow-ups and their status.
- [`host-hardening-tracker.md`](./host-hardening-tracker.md) — host-hardening audit + remediation state.
- [`api-security-status.md`](./api-security-status.md) — per-API security tiers + checklist.
- [`doc-drift-audit-2026-06-07.md`](./doc-drift-audit-2026-06-07.md) — documentation drift sweep record.
- [`infrastructure-retirement.md`](./infrastructure-retirement.md) — `infrastructure/` → `platform/` retirement.

## Operational references

- [`operator-cheatsheet.md`](./operator-cheatsheet.md) — common operator commands.
- [`glossary.md`](./glossary.md) — term definitions.
- [`claude-model-selection.md`](./claude-model-selection.md) — model-choice guidance.
- [`spiffe-ids.md`](./spiffe-ids.md) — canonical SPIFFE ID naming (trust domain `secforge.platform`).
- [`openbao-policies.md`](./openbao-policies.md) · [`spire-openbao-pattern.md`](./spire-openbao-pattern.md) — secrets/identity patterns.
- [`dpop-htu-canonicalization.md`](./dpop-htu-canonicalization.md) — DPoP `htu` rules.

## Security & scanning

- [`trivy-baseline.md`](./trivy-baseline.md) · [`dast-zap-setup.md`](./dast-zap-setup.md) — vuln/DAST baselines.
- [`wazuh-rule-conventions.md`](./wazuh-rule-conventions.md) · [`wazuh-sca-baseline.md`](./wazuh-sca-baseline.md) — Wazuh rules/SCA.
- [`transit-pii-encryption.md`](./transit-pii-encryption.md) — OpenBao Transit PII encryption pattern.

## Integrations & migration

- [`stripe-connect-migration-plan.md`](./stripe-connect-migration-plan.md) — Stripe Connect rollout (ADR-0034).
- Managed-cloud migration playbooks and the early edition/licensing briefs are **archived** (the
  bare-metal deployment superseded them): see [`../99-archive/`](../99-archive/)
  (`migration-to-vps.md`, `migration-to-aws.md`, `migration-keycloak-to-cognito.md`,
  `iam-oss-edition.md`, `iam-license-procurement-addendum.md`).

## What goes here vs. elsewhere

- **Architecture decisions and rationale** → `docs/02-decisions/`
- **How a component works in our deployment** → `docs/01-architecture/`
- **How to operate / debug / recover a component** → `docs/03-runbooks/`
- **Reference material, trackers, standards** → here
