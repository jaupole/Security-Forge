# CI secrets-check workflow — branch protection setup

> **Source of truth:** [`templates/app-repo/.github/workflows/secrets-check.yml`](../../templates/app-repo/.github/workflows/secrets-check.yml)
> **Related:** [new-app-bootstrap.md](./new-app-bootstrap.md), [secrets-library.md](./secrets-library.md)

This runbook covers the GitHub branch-protection setup that makes
`secrets-check.yml` a required check on the default branch — the layer
that ensures `git commit --no-verify` cannot bypass the guardrails into
a merge.

## Why a runbook for this

The workflow itself ships in `templates/app-repo/.github/workflows/`.
What it asserts (block-env-files, block-secret-shaped-vars, hadolint,
dockerfile-no-env-copy, artifact-upload-guard) is fully scripted. The
**enforcement** — making this required for merge — is a GitHub repo
configuration step that no script in this repo can do automatically.

This runbook is the operator-side checklist: do this once per app repo
when it's stood up, then the pre-commit + CI guardrails together cover
ADR-0013 § Layers 1 + 2.

## One-time setup

In each app repo's GitHub settings:

### Step 1 — Confirm the workflow ran at least once

Push or PR something to trigger the workflow. The required-status-check
selector below only lists checks that have run at least once in the
repo's history.

### Step 2 — Create a branch protection rule on `main`

GitHub repo → **Settings** → **Branches** → **Add rule**:

- **Branch name pattern**: `main`
- **Require a pull request before merging**: ✅
  - **Require approvals**: 1 (or more, per team policy)
  - **Dismiss stale pull request approvals when new commits are pushed**: ✅
- **Require status checks to pass before merging**: ✅
  - **Require branches to be up to date before merging**: ✅
  - **Status checks**: tick every job from `secrets-check.yml`:
    - `gitleaks`
    - `block-env-files`
    - `block-secret-shaped-vars`
    - `hadolint`
    - `dockerfile-no-env-copy`
    - `artifact-upload-guard`
- **Require signed commits**: ✅ (per project standard — see ADR-0021)
- **Do not allow bypassing the above settings**: ✅
- **Restrict who can push to matching branches**: optional, per team policy

### Step 3 — Confirm enforcement

Try to push a `--no-verify` commit containing a tracked `.env` file:

```bash
echo "TEST=x" > .env
git add -f .env
git commit -m "test branch protection" --no-verify
git push origin <feature-branch>
```

Open a PR. Expect:

- The `block-env-files` job fails with the ADR-0013 error message.
- "Merge pull request" is grayed out because the required check is failing.
- The PR cannot be merged until the `.env` is removed.

Clean up: `git rm .env && git commit --amend --no-edit && git push -f`
(force-push to your feature branch is fine; the protection rule applies
to `main`, not feature branches).

## Branch protection on the platform repo itself

The platform repo (this one) doesn't ship the per-template
`secrets-check.yml` because the templates ARE the source of truth for
that workflow. The platform repo's CI guardrails live separately:

- The repo-root `.pre-commit-config.yaml` (gitleaks, check-yaml,
  detect-private-key, check-added-large-files)
- The repo-root `.gitignore` (which has its own `.env*` patterns)

If/when the platform repo grows app-shaped sub-modules with their own
`.env` patterns, mirror this runbook's setup against the platform's
own `main` branch.

## Adding the webhook for Phase 7b

Once Phase 7b lands, the `secrets-check.yml` workflow will gain a step
that POSTs `secrets.guardrail.bypass` events to the in-cluster
`security-events-collector`. The webhook URL is sourced from a repo
secret:

```
SECURITY_EVENTS_WEBHOOK_URL = https://<ingress-host>/v1/secrets/guardrail/bypass
SECURITY_EVENTS_CI_TOKEN    = <short-lived JWT minted by security-events-ci client>
```

Both secrets are GitHub Actions secrets (NOT environment variables in
the repo's code). The `security-events-ci` Keycloak client is
provisioned at platform-onboarding time (see commit 4's operator-time
prerequisites in PLAN.md).

## Common pitfalls

| Symptom | Likely cause |
|---|---|
| "Required status check is not configured" warning | The workflow hasn't run yet on this branch — push something to trigger it. |
| Required-checks selector empty | Same — GitHub only lists checks that have a run history. |
| `block-env-files` job passing on a tracked `.env` | The `.env.example` allow-list pattern matched — confirm the file path doesn't end in `.example`. |
| `gitleaks-action` reports a finding on a committed test fixture | Use the split-and-concat pattern from `apps/security-events-collector/redact_test.go` so the literal isn't a real-shape credential. |

## Related

- [`templates/app-repo/.github/workflows/secrets-check.yml`](../../templates/app-repo/.github/workflows/secrets-check.yml) — the workflow itself
- [new-app-bootstrap.md](./new-app-bootstrap.md) — the cp-and-init pattern that gets the workflow into a new repo
- [secrets-guardrails-verification.md](./secrets-guardrails-verification.md) — verify the layers fire
- [ADR-0013 § 2](../02-decisions/0013-outbound-secrets-no-env.md) — the CI layer of the guardrail stack
- [ADR-0021](../02-decisions/0021-git-initialization-and-commit-signing.md) — signed-commits requirement
