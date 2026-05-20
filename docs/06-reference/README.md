# Reference Documents

This directory contains long-form reference material that supports decisions throughout the platform build, plus migration playbooks for when you eventually leave local.

## Architecture references

- **[iam-oss-edition.md](./iam-oss-edition.md)** — The full architecture brief for the open-source IAM platform. Read this when you need the rationale for a specific component choice (Why Keycloak? Why SpiceDB? Why this BFF pattern?). It's also the source-of-truth document for the platform's design decisions.
- **[iam-license-procurement-addendum.md](./iam-license-procurement-addendum.md)** — License analysis of every component. Read this when you need to confirm what's permissively licensed, what to commercially upgrade later, and how to handle SLA gaps.

## Operational references

These are populated as you go through the phases (each phase prompt creates the relevant file):

- `spiffe-ids.md` — canonical SPIFFE ID naming scheme (Phase 2)
- `openbao-policies.md` — what each policy can do (Phase 5)
- `screenshots/` — UI screenshots of dashboards and Hello World (Phase 9)

## Migration playbooks

When you outgrow local development:

- **[migration-to-vps.md](./migration-to-vps.md)** — Move to a single self-hosted server (homelab or VPS like Hetzner/OVH/DigitalOcean). Cheapest production-realistic option.
- **[migration-to-aws.md](./migration-to-aws.md)** — Move to AWS managed services (EKS, RDS, S3, KMS, etc.). Most expensive but most managed.

Both playbooks emphasize what changes (the substrate) and what stays (your apps, BFF, schema, policies).

## What goes here vs. elsewhere

- **Architecture decisions and rationale** → `docs/02-decisions/`
- **How a component works in our deployment** → `docs/01-architecture/`
- **How to operate / debug / recover a component** → `docs/03-runbooks/`
- **Reference material that doesn't fit above** (industry standards, license analysis, broad design briefs, migration playbooks) → here
