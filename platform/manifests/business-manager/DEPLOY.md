# Business Manager — deploy runbook (ecosystem app `managerapp`)

> **Routine image deploys no longer use this runbook.** Since 2026-06-11
> (ADR-0040) they are one command:
> `gh workflow run deploy-app.yml -R jaupole/Security-Forge -f app=business-manager -f digest=sha256:…`
> — see [deploy-app-image.md](../../../docs/03-runbooks/deploy-app-image.md).
> This document remains the FIRST-INSTALL / infrastructure guide.

Project Tracker, renamed **Business Manager**, deployed at **`bm.secforge.dev`**
(tailnet-only). App code lives in the `jaupole/business-manager` repo (was the
`Project Tracker` working copy). This is the operator-time sequence; the code +
manifests + Keycloak/OpenBao plumbing are already committed.

## Status (2026-06-11)

- ✅ **Step 0 DONE** — repo `jaupole/business-manager` created + pushed; rootless
  self-hosted runner registered; first image **built + cosign-signed + pinned**:
  `ghcr.io/jaupole/business-manager@sha256:3954cf956bae08f85c6011a262dc5e0b829f18a5063a5d4a796b6a134bf2b0e5`
  (commit 19df17e) — already pinned in `08`/`09`.
- ⏳ **Remaining (operator):** §1 OpenBao policy/role/KV → §2 Keycloak client +
  secret publish → §3 apply manifests → §4 Control migration 070 (pushed) +
  redeploy + activate `managerapp` → §5 hosts file + verify.

All `kubectl`/apply on the box runs as `ops` (`export KUBECONFIG=$HOME/.kube/config`).
**Never** `kubectl apply -f` a manifest with `${...}` — always go through
`platform/lib/apply-manifest.sh` (envsubst).

## 0. Bootstrap the GitHub repo + first image

1. Create **private** repo `jaupole/business-manager`. Push the Business Manager
   working copy (`C:\Users\jaupo\Projects\Project Tracker`, branch is fine) to it:
   `git remote add origin git@github.com:jaupole/business-manager.git && git push -u origin HEAD`.
2. Register the rootless self-hosted runner for it:
   `cd ~/secforge/platform && git pull && bash scripts/github-runners-bootstrap.sh`
   (the `[business-manager]=business-manager` REPOS row is already in place).
3. The push triggers `business-manager-image-build` → typecheck + `prisma migrate
   deploy` against an ephemeral Postgres + Trivy gates + **cosign-signed** image.
   Capture the signed digest from the run summary.
4. **Pin the digest** into BOTH `08-migration-job.yaml` and `09-deployment.yaml`
   (replace the `sha256:0000…` placeholder — they MUST match), commit, push.

## 1. OpenBao policy + VSO role + KV (operator-time)

```sh
cd ~/secforge/platform && git pull
# Policy: vso.hcl now grants read on apps/business-manager/+ — re-apply it
bao policy write vso manifests/openbao/policies/vso.hcl
# k8s-auth role business-manager-vso (row added to APP_ROLES)
bash components/05j-app-vso-roles.sh
# Populate the runtime KV (NO secrets in this file — generate inline):
bao kv put secret/apps/business-manager/runtime \
  session_signing_key="$(openssl rand -base64 32)" \
  sam_gov_api_key="<sam.gov key>"            # optional; poller-only
# GHCR image-pull (classic PAT with read:packages on jaupole/business-manager):
bao kv put secret/apps/business-manager/ghcr-pull username="jaupole" password="<ghcr-pat>"
```

`oidc_client_secret` is published by step 2 below — do **not** hand-set it.

## 2. Keycloak client + secret publish

The `business-manager` confidential client is declared in
`manifests/keycloak/realms/platform-realm.yaml` (auth-code + PKCE, redirect
`https://bm.secforge.dev/*`, self + control audience, back-channel logout).
Re-apply the realm import (or add the client in the admin console to match),
then bridge its secret into OpenBao:

```sh
bash components/05l-keycloak-secret-publish.sh   # writes apps/business-manager/runtime#oidc_client_secret
```

## 3. Apply manifests (order matters)

> Prereq: the `09` Deployment mounts the `openbao-internal-ca-cert` configmap,
> distributed by trust-manager only to namespaces named in
> `manifests/trust-manager/01-bundles.yaml`. `business-manager` is now in that
> Bundle's selector — apply it if not already live:
> `bash lib/apply-manifest.sh manifests/trust-manager/01-bundles.yaml`
> (the configmap appears in the ns within seconds, else the pod hangs FailedMount).

```sh
cd ~/secforge/platform && git pull
M=manifests/business-manager
bash lib/apply-manifest.sh $M/01-namespace.yaml
bash lib/apply-manifest.sh $M/03-serviceaccount.yaml
bash lib/apply-manifest.sh $M/04-vso-bindings.yaml      # wait: kubectl -n business-manager get secret business-manager-app-secrets ghcr-pull-secret cnpg-minio-credentials
# CRITICAL: the ObjectStore (06) MUST exist BEFORE the cluster (02). The
# barman-cloud plugin's pre-reconcile hook STOPS the cluster reconcile loop
# ("barman object configuration not found, requeuing") until minio-backup
# exists, and it does NOT auto-recover if 02 is applied first — you'd have to
# `kubectl -n business-manager annotate cluster business-manager-db
# force-reconcile=$(date +%s) --overwrite` to unstick it.
bash lib/apply-manifest.sh $M/06-objectstore.yaml
bash lib/apply-manifest.sh $M/02-cnpg-cluster.yaml      # wait: cnpg cluster business-manager-db Ready (1/1)
bash lib/apply-manifest.sh $M/07-cnpg-scheduled-backup.yaml  # after the cluster exists
bash lib/apply-manifest.sh $M/08-migration-job.yaml     # wait: job business-manager-db-migrate Complete
bash lib/apply-manifest.sh $M/05-network-policies.yaml
bash lib/apply-manifest.sh $M/09-deployment.yaml        # wait: deploy Ready 1/1 (/readyz green)
bash lib/apply-manifest.sh $M/10-services.yaml
bash lib/apply-manifest.sh manifests/istio-ingress/20-virtualservices.yaml   # adds bm.${DOMAIN}
```

## 4. Control registration + activation

```sh
# Apply Control migration 070 (display_name → "Business Manager") + redeploy
# Control so roles.ts picks up the rename, then activate the app for the org:
#   Control admin UI → org → Apps → activate `managerapp` (Business Manager)
```
Without activation every non-auth route 403s the app-activation gate.

## 5. Operator host + verify

- Add `bm.secforge.dev → <tailnet IP>` to the operator hosts file (split-DNS).
- **Login:** `https://bm.secforge.dev` → Keycloak (platform realm) → callback →
  `__Host-bm_sess` set, SPA loads.
- **Activation gate:** deactivate `managerapp` → non-auth routes 403; reactivate → ok.
- **RLS:** the FORCE-RLS isolation was validated pre-deploy as a non-superuser
  role (org-B sees 0 of org-A's rows; cross-org INSERT rejected by WITH CHECK;
  no-GUC read = 0). Spot-check in prod with a second org if available.
- **Reports:** generate a report → streams a PDF via Gotenberg (no Chromium).
- **(optional) seed** the operator org's opp-watch tracks:
  `BM_SEED_ORG_ID=<org-uuid> pnpm db:seed` (run from a checkout against the DB).

## Notes / deferred
- Background cron (digest + opp-poller) is OFF in prod — needs a multi-org
  `runWithOrgContext` fan-out + `.mjs` packaging (`BM_ENABLE_SCHEDULER`).
- Stale `openbao/policies/project-tracker.hcl` (local-edition: `secforge.local`,
  `ns/app`, dynamic DB creds) is dead config superseded by the VSO model — safe
  to delete in a cleanup pass.
- No app-MinIO + no SpiceDB egress day-1 (org-tier + RLS authz).
