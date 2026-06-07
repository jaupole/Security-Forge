# Runbook — `member-hub-documents` MinIO credentials

**Purpose.** Provision the per-app MinIO service account that Member
Hub's document-attachment API uses to read/write the
`member-hub-documents` bucket (member, sponsor, prospect, and event
file attachments).

**Why this is a separate step.** `platform/manifests/minio/02-bucket-bootstrap-job.yaml`
creates the *bucket* (versioned + SSE-S3) but deliberately owns no
credentials. The MinIO **user + bucket-scoped policy** are created by
this runbook. The user's access/secret key are generated once and stored
in OpenBao at `secret/minio/member-hub-documents`; VSO renders them into
the `member-hub` namespace Secret `member-hub-documents-minio`
(see `manifests/member-hub/04-vso-bindings.yaml`), which the app reads
via `envFrom` as `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY`.

> **Symptom this prevents.** If the OpenBao entry exists (so the app has
> credentials) but the matching MinIO user was never created, every
> document upload/download 500s with
> `S3Error: The Access Key Id you provided does not exist in our records.`
> (`InvalidAccessKeyId`). First hit in prod 2026-06-07, right after the
> sponsor/prospect/event document feature shipped — the member-documents
> path had simply never been exercised against prod MinIO before.

## Prerequisites

- The OpenBao entry `secret/minio/member-hub-documents` exists with
  `MINIO_ACCESS_KEY` + `MINIO_SECRET_KEY` (VSO `member-hub-documents-minio-vso`
  reports `SecretSynced=True`).
- The `member-hub-documents` bucket exists (bootstrap Job has run).
- `kubectl` on the box (`ssh secforge`, `ops` user).

## Procedure

All commands run on `secforge-prod`.

### 1. Confirm the bucket exists

The bootstrap Job owns it (versioned + SSE-S3). If a fresh cluster, run
`platform/components/07a-minio.sh` first. The credentials Job below also
does a defensive `mc mb --ignore-existing`, but it does **not** set
versioning/encryption — those are the bootstrap Job's job.

### 2. Copy the app credential Secret into the `minio` namespace

A Job pod can only read Secrets from its own namespace, and the app
credential lives in `member-hub`. Copy it as base64 (no plaintext
decode):

```sh
A=$(kubectl -n member-hub get secret member-hub-documents-minio -o jsonpath='{.data.MINIO_ACCESS_KEY}')
S=$(kubectl -n member-hub get secret member-hub-documents-minio -o jsonpath='{.data.MINIO_SECRET_KEY}')
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: tmp-mh-docs-app
  namespace: minio
type: Opaque
data:
  MINIO_ACCESS_KEY: $A
  MINIO_SECRET_KEY: $S
EOF
```

### 3. Apply the credentials Job

Reads MinIO root creds and the copied app creds via `secretKeyRef`
(nothing on a command line); creates the `member-hub-documents-rw`
policy + the MinIO user and attaches the policy. Idempotent.

```sh
kubectl -n minio delete job member-hub-documents-credentials --ignore-not-found
kubectl apply -f ~/secforge/platform/manifests/minio/03-member-hub-documents-credentials-job.yaml
kubectl -n minio wait --for=condition=complete job/member-hub-documents-credentials --timeout=90s
kubectl -n minio logs job/member-hub-documents-credentials
```

Expect `Added user … successfully`, `Attached Policies: [member-hub-documents-rw]`.

### 4. Delete the transient copy

```sh
kubectl -n minio delete secret tmp-mh-docs-app
```

### 5. Verify

The app picks the creds up from its env immediately (no restart needed).
Upload a document in Member Hub (sponsor/prospect/event/member edit view)
and confirm the download works. Or check there are no fresh
`InvalidAccessKeyId` errors in the backend log:

```sh
POD=$(kubectl -n member-hub get pods -l app.kubernetes.io/name=member-hub --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n member-hub logs "$POD" -c api --since=5m | grep -i 'InvalidAccessKeyId' || echo "clean"
```

## Follow-up (not yet done)

Full automation would render `secret/minio/member-hub-documents` into the
`minio` namespace via VSO and let a bootstrap-style Job create the
user/policy with no manual secret copy — removing steps 2 and 4. That
needs a `minio`-namespace `VaultAuth` + an OpenBao k8s-auth role/policy
granting read on `secret/minio/member-hub-documents`. Tracked in the
operator backlog. Until then, this runbook is the DR-replay path.
