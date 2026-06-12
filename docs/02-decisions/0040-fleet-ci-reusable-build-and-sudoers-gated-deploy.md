# ADR-0040: Fleet CI/CD — reusable build workflow + sudoers-gated one-command deploys

Date: 2026-06-11
Status: Accepted (live in production)

## Context

By June 2026 the platform ran ~200 image builds and ~140 manual deploy
commits per 14 days across six first-party app repos. Each repo carried a
hand-synced copy of the same image-build workflow (build → push → cosign
sign → verify), and every deploy was an 8-step manual ritual: scrape the
digest from a run log, edit 2–4 manifest files, commit/push Security-Forge,
SSH to the box, delete the stale migration Job, `apply-manifest.sh` each
file, watch the rollout.

Two incidents on 2026-06-11 made the costs concrete:

- A dependabot bump of `cosign-installer` silently switched the signature
  format and broke every deploy at Kyverno admission (backlog #90). Fixing
  the fleet took **eight** separate edits — twice in one day (the cosign
  pin, then the DOCKER_CONFIG isolation).
- The manifests' cron digests had drifted across three image versions
  because manual bumps only touched the files someone remembered.

## Decision

**1. One reusable image-build workflow** —
`.github/workflows/reusable-image-build.yml` in this repo. Every app repo's
image-build workflow is a thin `workflow_call` caller (inputs: image,
title, description, context, build-args, trivy-gate). App-specific `test`
jobs stay in the app repos and gate the caller via `needs: test`. Callers
reference `@main` deliberately: SHA-pinning would re-introduce the
eight-edit problem, and the trust boundary is this repo, which also holds
the cluster manifests.

**2. One-command deploys from git** — `.github/workflows/deploy-app.yml`
(workflow_dispatch: app + digest). It bumps EVERY manifest pinning the
app's image (deployment, migration Job, CronJobs — drift cannot recur),
commits + pushes, then runs `sudo secforge-app-deploy <app>` on the box.
The wrapper (`/usr/local/sbin/secforge-app-deploy`, root-owned) git-pulls
the ops clone and executes the VERSIONED `platform/lib/deploy-app.sh`:
delete stale one-shot migration Job → apply + wait → apply the rest →
`kubectl rollout status` per Deployment. On failure: `kubectl rollout
undo` + the workflow reverts the bump commit, so git == cluster always.

**3. Trust model (the load-bearing part).** The `github-runner` OS account
holds **no kubeconfig and no cluster credential**. Its single privilege is
the sudoers-ENUMERATED wrapper (`/etc/sudoers.d/github-runner-deploy`, one
line per app, no wildcards). A compromised workflow can therefore only
trigger "deploy what main says for an allowlisted app" — it cannot apply
arbitrary manifests, reach kubectl, or escalate. Root executes ops-owned
files, which is the same trust as the pre-existing manual
`sudo bash lib/apply-manifest.sh` flow.

## Alternatives rejected

- **GitOps controller (Flux/ArgoCD + image automation):** adds a
  cluster-admin-ish controller to a single hardened node, removes the
  operator's deliberate deconfliction gate, and violates the "stop and ask
  before new tools" discipline — for marginal benefit over dispatch.
- **Scoped ServiceAccount kubeconfig for the runner:** even a namespaced,
  least-privilege token is a long-lived credential on disk for an account
  that executes semi-trusted workflow code — breaches the CLAUDE.md
  bright line on >24h credentials. The sudoers wrapper keeps the existing
  root kubeconfig as the only credential and gates it by fixed command.
- **Auto-deploy on merge:** rejected; the operator triggers deploys
  explicitly (deconfliction with parallel work is routine).

## Consequences

- **Keyless signing identity changed.** Inside `workflow_call`, Fulcio's
  certificate SAN is the *reusable workflow's* ref
  (`https://github.com/jaupole/Security-Forge/.github/workflows/reusable-image-build.yml@…`),
  not the app repo. Kyverno's `(secforge|jaupole)` subjectRegExp still
  matches. Follow-up (backlog #91a): tighten the policy to exactly this
  single identity — centralized signing makes that a real hardening gain.
- Shared-`$HOME` runner hazards (docker config, cosign install dir) are
  fixed once, centrally, with per-job isolation.
- `gotenberg`/`keycloak` image builds (this repo) are NOT yet callers —
  special steps (version build-arg, in-job trivy CLI, artifact upload;
  keycloak deploys via operator CR + server-side apply) keep them out of
  deploy-app v1 (backlog #91b).
- Runbook: [deploy-app-image.md](../03-runbooks/deploy-app-image.md) is the
  operational reference; the manual flow remains documented as fallback.

## Validation (day one)

The failure path proved itself before the happy path: the first dispatch
used a malformed digest, Kyverno denied admission, `deploy-app.sh` aborted
before touching the Deployment, and the workflow reverted the bump — git
and cluster never diverged. The second dispatch deployed control
(`3dadceaa`) in one command and unified the three drifted cron digests.
