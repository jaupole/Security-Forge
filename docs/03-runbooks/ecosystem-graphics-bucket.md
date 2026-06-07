# Runbook — Provision the `ecosystem-graphics` MinIO bucket credentials

The `ecosystem-graphics` bucket backs Ecosystem Control's org graphics
library (PDF/email/website graphics + the canonical `org_logo`). The
bucket is created by `platform/manifests/minio/02-bucket-bootstrap-job.yaml`
and the app's MinIO key/secret live in OpenBao (`secret/minio/ecosystem-graphics`),
rendered into the control namespace as the `ecosystem-graphics-minio`
Secret by the VSO binding in `platform/manifests/control/04-vso-bindings.yaml`.

What's NOT automatic: creating the matching **MinIO user + bucket-scoped
policy**. Without it, every graphics upload 500s with
`InvalidAccessKeyId`. This runbook closes that gap. Mirror of
`member-hub-documents-bucket.md`.

> Surfaced 2026-06-07: `org_graphics` had never been written to in prod,
> so the missing user lay dormant until the `org_logo` backfill hit it.

## Procedure

All `kubectl` runs as root on the box (`sudo -n kubectl`; kubeconfig is 0600).

```bash
# 1. Confirm the bucket exists (bootstrap Job owns it; idempotent check).
sudo -n kubectl -n minio get job minio-bucket-bootstrap

# 2. Copy the app key/secret from control ns into minio ns as a temp
#    Secret (base64 passthrough — no plaintext, no secret on a cmdline).
sudo -n kubectl -n control get secret ecosystem-graphics-minio -o json \
  | jq '{apiVersion,kind,type,
         metadata:{name:"tmp-eco-graphics-app",namespace:"minio"},
         data:{MINIO_ACCESS_KEY:.data.MINIO_ACCESS_KEY,
               MINIO_SECRET_KEY:.data.MINIO_SECRET_KEY}}' \
  | sudo -n kubectl apply -f -

# 3. Apply the credentials Job (creates the user + ecosystem-graphics-rw
#    policy + attaches it). No envsubst placeholders, so a direct apply
#    is fine.
sudo -n kubectl apply -f \
  ~/secforge/platform/manifests/minio/03-ecosystem-graphics-credentials-job.yaml
sudo -n kubectl -n minio wait --for=condition=complete \
  job/ecosystem-graphics-credentials --timeout=120s
sudo -n kubectl -n minio logs job/ecosystem-graphics-credentials   # → "--- user info ---"

# 4. Delete the temp Secret — it has served its purpose.
sudo -n kubectl -n minio delete secret tmp-eco-graphics-app
```

## Verify

Run the graphics path end-to-end — e.g. the org-logo backfill (a separate
node process inside the running pod, so it won't touch the server's pool):

```bash
sudo -n kubectl -n control exec deploy/control -c api -- \
  /nodejs/bin/node dist/scripts/backfill-org-logos.js --dry-run
```

A clean dry-run that no longer reports `InvalidAccessKeyId` confirms the
user can reach the bucket. Then run it for real (drop `--dry-run`).

## Backlog

Same as member-hub-documents (#81): fold the user/policy creation into a
VSO-driven automation so a fresh cluster provisions it without this manual
copy. Until then this Job is the documented path.
