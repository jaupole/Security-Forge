# DAST: ZAP baseline scan setup

ZAP baseline workflows are wired in three repos:

| Repo | Workflow file | Target |
|---|---|---|
| `Security Forge` | `.github/workflows/dast-zap-baseline.yml` | `auth.${DOMAIN}` (Keycloak public ingress) |
| `Ecosystem Portal` | `.github/workflows/dast-zap-baseline.yml` | Portal staging URL |
| `Ecosystem Control` | `.github/workflows/dast-zap-baseline.yml` | Control API staging URL |

All three:
- Run on PR to `main` (gating)
- Run nightly at 03:30 UTC (regression watch)
- Run on `workflow_dispatch` with optional URL override
- Skip cleanly if no target is configured (warning, no failure)

## Required GitHub secret

Each repo needs `ADVISOR_STAGING_URL` set as a repository secret pointing at
the URL ZAP should scan.

```
gh secret set ADVISOR_STAGING_URL --repo <org>/<repo> --body "https://auth.secforge.dev"
```

Recommended values:

| Repo | Value |
|---|---|
| `Security Forge` | `https://auth.secforge.dev` |
| `Ecosystem Portal` | `https://portal.secforge.dev` (once deployed) |
| `Ecosystem Control` | `https://api.secforge.dev` (once deployed) |

## Optional: GitHub Actions runner IP allowlisting

Keycloak's public ingress has rate limits (5 rps + burst ×3, 20 conn). A
ZAP baseline scan is ~50 requests over ~10s, well within burst capacity.
No special allowlisting is required.

If a future scan hits the limit, two options:

1. Set the `ADVISOR_STAGING_URL` to a private staging deployment that
   has no rate limit, OR
2. Add GH Actions IP ranges to `nginx.ingress.kubernetes.io/whitelist-source-range`
   on the Keycloak ingress for the brief scan window.

GH Actions IP ranges are documented at
https://api.github.com/meta and rotate daily — option 1 is simpler.

## Baseline findings as of 2026-05-14

Last manual run against `https://auth.secforge.dev`:
- **PASS: 66**
- **FAIL: 0**
- **WARN: 1** (Non-Storable Content on 503 error pages — cosmetic, no
  data leak; would require nginx server-snippet templating to fix)

## When ZAP fails a PR

The action opens or updates a GitHub issue titled
"DAST: ZAP baseline findings" containing the full report. Triage:

- **FAIL-NEW**: blocker. Investigate and fix before merge.
- **WARN-NEW**: review. If the warning is on a path that doesn't exist
  in the upstream app (e.g. `/sitemap.xml` on Keycloak), add an entry to
  `.zap/rules.tsv` in the affected repo with `IGNORE` to suppress.
- **PASS-NEW**: improved coverage — no action.

## Removing this gate

If a repo has no public-facing endpoint to scan, the workflow can be
disabled with a single `if: false` line on the `zap-baseline` job, or
the file can be deleted entirely.
