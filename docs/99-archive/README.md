# Archive

Historical documentation kept for the record. **Nothing in this folder reflects the current
production deployment.** It describes the original *local-first* build of the platform — Docker
Desktop Kubernetes, WSL2, the `secforge.local` domain, TOTP, and Teleport — before the migration
to the single public Hetzner bare-metal k3s node (`secforge-prod`, `*.secforge.dev`).

For current state, start at:

- [`PLAN.md`](../../PLAN.md) — production status snapshot.
- [`docs/01-architecture/`](../01-architecture/) — how the live platform works.
- [`docs/03-runbooks/`](../03-runbooks/) — operational procedures.
- [`docs/06-reference/operator-backlog.md`](../06-reference/operator-backlog.md) — open work.

## What's here

| Path | What it was |
|---|---|
| `00-getting-started/` | Local-edition onboarding (Docker Desktop, WSL2, local DNS/TLS, first session). |
| `05-claude-code-prompts/` | The phase-by-phase build prompts (phase-00 … phase-11). The platform build they describe is complete. |
| `PLAN-local-edition.md` | The original local-edition build plan with its phase-status table. |
| `migration-to-aws.md`, `migration-to-vps.md`, `migration-keycloak-to-cognito.md` | Alternative deployment-path planning, superseded by the bare-metal decision. |
| `iam-oss-edition.md`, `iam-license-procurement-addendum.md` | Early edition/licensing planning. |

Why archived rather than deleted: ADRs and prompts reference this history, and the build record is
useful context. Git history preserves the moves (`git log --follow`).
