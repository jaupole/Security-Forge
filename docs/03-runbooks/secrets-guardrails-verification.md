# Outbound-secrets guardrail verification suite

> **Source of truth:** [`infrastructure/secrets-guardrails/verify/`](../../infrastructure/secrets-guardrails/verify/)
> **ADR:** [ADR-0013 § Multi-layer prevention guardrails](../02-decisions/0013-outbound-secrets-no-env.md#3-multi-layer-prevention-guardrails)

This runbook documents the executable verification suite that probes
every layer of ADR-0013's guardrail stack. The point: **manual
checklists rot** — every one of the eight failure modes the guardrails
prevent has its own `bash` script that deliberately commits the
violation and asserts the layer fires.

Phase 7 schedules `run-all.sh` as a weekly CronJob; failures emit
`severity=critical` events.

## Prerequisites

The scripts run on the operator's WSL host (or any machine with
`docker`, `kubectl`, and `pre-commit`). Different scripts have
different needs:

| Script | Needs |
|---|---|
| 01 | `pre-commit` installed; clean working tree |
| 02 | `docker` |
| 03 | `docker` (offline) OR `kubectl` (LIVE=1) |
| 04 | `docker` |
| 05 | `pre-commit` installed; clean working tree |
| 06 | `docker` |
| 07 | `docker` |
| 08 | `docker` (offline) OR `kubectl` (LIVE=1) |

`pre-commit` install: `pipx install pre-commit && pre-commit install`
(in the repo root).

## Run the suite

```bash
# Offline-only (no live cluster touched):
bash infrastructure/secrets-guardrails/verify/run-all.sh

# Including the live-cluster cases (operator-only, after manifests applied):
LIVE=1 bash infrastructure/secrets-guardrails/verify/run-all.sh
```

Expected output (all green):

```
SecForge guardrail verification suite (ADR-0013)
──────────────────────────────────────────────────

▶ 01-precommit-blocks-env.sh
   ✓ 01-precommit-blocks-env.sh
▶ 02-ci-blocks-no-verify.sh
   ✓ 02-ci-blocks-no-verify.sh
▶ 03-kyverno-denies-secret-env.sh
   ✓ 03-kyverno-denies-secret-env.sh
... (5 more)

Summary: 8/8 passed, 0 failed, 0 setup-issue
ALL GUARDRAIL LAYERS HEALTHY ✅
```

## What each script proves

| # | Script | Layer | Asserts |
|---|---|---|---|
| 01 | `precommit-blocks-env` | 1 (developer) | Pre-commit's `block-env-files` rejects a staged `.env` |
| 02 | `ci-blocks-no-verify` | 2 (CI) | The `block-env-files` job in `secrets-check.yml` flags a tracked `.env` even after `--no-verify` |
| 03 | `kyverno-denies-secret-env` | 4 (admission) | Kyverno `no-secret-shaped-env-vars` denies a Pod with `STRIPE_API_KEY` env |
| 04 | `trivy-fails-on-env-in-image` | 3 (build-time) | Trivy `--scanners vuln,secret` fails an image carrying a Stripe-shaped key |
| 05 | `precommit-blocks-secret-getenv` | 1 (developer) | Pre-commit's `block-secret-shaped-vars` rejects `os.Getenv("OPENAI_KEY")` in Go source |
| 06 | `secret-redacts-in-printf` | 5 (runtime) | `Secret.String()` and `MarshalJSON()` redact across `fmt.Printf` and `json.Marshal` |
| 07 | `secret-redacts-in-panic` | 6 (error reporting) | `apps/lib/errreport/` `ScrubbingReporter` redacts five vendor-prefix sigils before reaching the sink |
| 08 | `annotated-bypass-emits-event` | 4 escape hatch | A Pod with `legacy-secret-env` annotations is admitted AND emits an `outcome: annotated-bypass` event |

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | All scripts passed | Nothing — guardrails healthy |
| 1 | At least one script FAILED | A guardrail layer regressed; re-run the failing script standalone for full output |
| 2 | At least one script SKIPPED on setup | Install missing tools (docker / pre-commit / kubectl), re-run |

## Adding a 9th case

When a new guardrail layer is added (e.g., a runtime DPoP-binding check
on outbound credential use), file an ADR amendment and add a
`09-<short-name>.sh` to the verify directory. The pattern:

```bash
#!/usr/bin/env bash
# Verify 09: <Layer name> — <one-line description>
#
# <Two-paragraph context: why the layer exists, what it protects>
#
# Exit codes: 0 pass / 1 fail / 2 setup
set -euo pipefail
# ... pre-checks ...
# ... deliberately commit the violation ...
# ... assert the layer fires ...
```

The numbering matters; `run-all.sh` globs `[0-9][0-9]-*.sh` in shell
sort order so `09` lands after `08`. Don't introduce subletter
conventions like `08a`.

## Troubleshooting

### Script 01 / 05 fail with "working tree dirty"

Stash or commit any in-progress edits before running. The scripts
refuse to run on a dirty tree because `git reset HEAD --` in the
trap could undo unrelated work.

### Script 02 reports "no .env detected"

The CI mirror runs against a fresh `mktemp` repo, so this is rare.
If you see it, the synthetic `git add -f .env` step failed — check
that the mktemp dir was writeable.

### Script 03 (offline) shows "Want fail, got error" for a rule

Kyverno's CEL/JMESPath substitution returned `nil` for a variable.
Common causes: `time_until` doesn't exist in v1.13 (use `time_since`
with negative-duration comparisons); the `request.object.metadata.annotations.<key>`
lookup failed (annotation missing — check the fixture).

### Script 04 fails the BUILD (not Trivy)

The synthetic `Dockerfile` is too thin; check `docker build` output.
Most likely cause: `alpine:3.20` not in the local cache; pre-pull with
`docker pull alpine:3.20`.

### Script 06 / 07 fail with "program failed to run"

The dockerized Go module couldn't resolve the `replace` target.
Confirm the bind-mount path: `-v $REPO_ROOT/apps/lib:/lib`. The script
expects to be invoked from the platform repo root.

### Script 08 (LIVE=1) admission allowed but no event seen

The CronJob runs at 06:00 UTC daily; for ad-hoc verification trigger:

```bash
kubectl create job --from=cronjob/legacy-env-warner -n app verify-08-warner
```

Then re-tail the collector logs.

## Related

- [`infrastructure/secrets-guardrails/verify/`](../../infrastructure/secrets-guardrails/verify/) — the scripts themselves
- [secrets-guardrails-monitoring.md](./secrets-guardrails-monitoring.md) — what the events look like once they fire
- [secrets-library.md](./secrets-library.md) — the library these guardrails protect
- [ADR-0013](../02-decisions/0013-outbound-secrets-no-env.md) — the policy
