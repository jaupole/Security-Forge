# Proposal Forge — secforge-prod deploy runbook

> **Routine image deploys no longer use this runbook.** Since 2026-06-11
> (ADR-0040) they are one command:
> `gh workflow run deploy-app.yml -R jaupole/Security-Forge -f app=proposal-forge -f digest=sha256:…`
> — see [deploy-app-image.md](./deploy-app-image.md). This document remains
> the FIRST-INSTALL / infrastructure cutover guide (namespaces, secrets,
> Keycloak client, MinIO, network policies).

> App: `proposalapp` · Namespace: `proposal-forge` · Access: **tailnet-only**
> (no public DNS A record; CGNAT-whitelisted ingress + hosts-file entry).
> Architecture: [docs/01-architecture/apps/proposal-forge.md](../01-architecture/apps/proposal-forge.md)

This runbook covers the **interactive cutover session** — the steps that need
the operator's credentials (Keycloak admin console, OpenBao token, MinIO admin,
Portal UI) and therefore can't be fully scripted. Everything ahead of these
steps is already done and committed:

| Done (automated / committed) | Where |
| --- | --- |
| Ecosystem code (OIDC + SpiceDB + org RLS + MinIO), merged | PF `master` @ `b4c0d30` |
| Signed image built + cosign-verified | `ghcr.io/jaupole/proposal-forge@sha256:4139a407a713b814d379dbbce260812af918e93be69bc15138836864dcfc9d7f` |
| Digest pinned in migration Job + Deployment | `08-migration-job.yaml`, `09-deployment.yaml` |
| Scaffolding applied to cluster | ns, 2 SA, 13 NetworkPolicies, CA configmap, Service, Ingress, Kyverno tailnet policy |
| `proposal-forge-tls` cert issuing (DNS-01) | `proposal-forge` ns |
| OpenBao `vso.hcl` paths + `05j` role codified | `vso.hcl`, `05j-app-vso-roles.sh` |
| SpiceDB `proposalapp/proposal` type + tests | `ecosystem-schema.zed`; `tests/run.sh` 12/12 green |

The cluster scaffolding was applied from `origin/main` via a detached checkout
of `~/secforge`, then the operator's `sec/keycloak-master-flow-replay` branch was
restored. Pull `~/secforge` to `origin/main` (after dealing with that branch's
unpushed commit `4e1a3c5`) before re-running any component script below.

---

## Order of operations

The steps are dependency-ordered. Don't skip ahead — each unblocks the next.

```
1. Keycloak client  ─┐
2. OpenBao session   ├─→ 5. Apply VSO bindings ─→ 6. CNPG ─→ 7. Migration ─→ 8. Deployment ─→ 9. Control org/activate ─→ 10. Verify
3. MinIO bucket     ─┘                              ↑
4. SpiceDB schema ─────────────────────────────────┘ (independent; do any time before step 8)
```

---

## 1. Keycloak client (admin console — browser)

The `proposal-forge` client is codified in
[`platform/manifests/keycloak/realms/platform-realm.yaml`](../../platform/manifests/keycloak/realms/platform-realm.yaml)
(lines ~865–919) for DR, but `KeycloakRealmImport` is one-shot, so the **live**
platform realm needs it created by hand. Per
[[project_keycloak_admin_db_only]] automated changes go via direct Postgres —
but a one-off client created by **jaupole logged into the admin console** is the
intended path and far safer than hand-written SQL.

1. Sign in to the Keycloak admin console (`https://auth.secforge.dev/admin`
   — `/admin` is the tailnet-only CGNAT-whitelisted ingress; master-realm admin
   `jaupole`, WebAuthn). Switch the realm dropdown (top-left) to `platform`.
2. **Clients** → **Import client**, paste the JSON below (DOMAIN already
   resolved to `secforge.dev`), or create it manually to match.
3. After save, that's it — **no need to copy the secret**.
   `05l-keycloak-secret-publish.sh` reads `CLIENT.secret` straight from the
   Keycloak DB and publishes it to `secret/apps/proposal-forge/runtime#oidc_client_secret`
   (step 2f). This is also what makes a DR rebuild self-healing — the realm-import
   regenerates the secret and 05l re-publishes it, no manual step.

```json
{
  "clientId": "proposal-forge",
  "name": "Proposal Forge",
  "description": "Proposal Forge user-facing OIDC (browser auth-code + PKCE). App proposalapp.",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "clientAuthenticatorType": "client-secret",
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "redirectUris": ["https://pf.secforge.dev/*"],
  "webOrigins": ["https://pf.secforge.dev"],
  "attributes": {
    "post.logout.redirect.uris": "https://pf.secforge.dev/*",
    "backchannel.logout.session.required": "true",
    "backchannel.logout.revoke.offline.tokens": "false",
    "frontchannel.logout.session.required": "true",
    "oauth2.device.authorization.grant.enabled": "false",
    "oidc.ciba.grant.enabled": "false",
    "standard.token.exchange.enabled": "false",
    "display.on.consent.screen": "false",
    "pkce.code.challenge.method": "S256"
  },
  "protocolMappers": [
    {
      "name": "proposal-forge-audience",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-audience-mapper",
      "consentRequired": false,
      "config": {
        "included.client.audience": "proposal-forge",
        "access.token.claim": "true",
        "id.token.claim": "false",
        "introspection.token.claim": "true",
        "lightweight.claim": "false",
        "userinfo.token.claim": "false"
      }
    },
    {
      "name": "control-audience-for-getme",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-audience-mapper",
      "consentRequired": false,
      "config": {
        "included.custom.audience": "control",
        "access.token.claim": "true",
        "id.token.claim": "false",
        "introspection.token.claim": "true",
        "lightweight.claim": "false"
      }
    }
  ]
}
```

> The `pkce.code.challenge.method: S256` attribute is added here (the YAML omits
> it; the PF backend always sends PKCE, but forcing it server-side is strictly
> safer). Self-audience `aud=proposal-forge` lets the backend strict-audience-check;
> cross-audience `aud=control` lets it call Control `/api/v1/me` for org context.

---

## 2. OpenBao session (token + CLI)

Mint an admin token (break-glass via the `admin-break-glass` k8s-auth role, or
admin-OIDC) and stage it as the `openbao-root-token-tmp` Secret that the
component scripts read. **Delete that Secret at the end of the day** ([[project_openbao_root_token_cleanup]]).
Never `bao token revoke -self` ([[feedback_no_bao_token_revoke_self]]).

```bash
# On the box (sudo -n kubectl). TOK = a fresh admin token.
kubectl create secret generic openbao-root-token-tmp -n openbao --from-literal=token="$TOK"
B(){ kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$TOK" "$@"; }

# 2a. Update the shared vso policy to include the proposal-forge paths.
B bao policy write vso - < ~/secforge/platform/manifests/openbao/policies/vso.hcl

# 2b. Create the k8s-auth role (idempotent; reads openbao-root-token-tmp).
bash ~/secforge/platform/components/05j-app-vso-roles.sh

# 2c. Runtime bundle — the OPERATOR-populated fields ONLY (oidc_client_secret
#     is added by 05l in 2f). spicedb_psk = the shared PSK; session_signing_key
#     = fresh 32-byte base64; gemini/gsa rotated. NOTE: `bao kv put` REPLACES
#     the whole path, so this MUST run BEFORE 05l (which merge-adds the secret).
PSK=$(sudo -n kubectl get secret -n spicedb spicedb-config-vso -o jsonpath='{.data.preshared_key}' | base64 -d)
B bao kv put secret/apps/proposal-forge/runtime \
    spicedb_psk="$PSK" \
    session_signing_key="$(openssl rand -base64 32)" \
    gemini_api_key='<rotated Gemini key>' \
    gsa_api_key='<GSA per-diem key>'

# 2d. GHCR image pull (classic PAT with read:packages — fine-grained doesn't
#     expose Packages, per project_member_hub_phase_b_deploy).
B bao kv put secret/apps/proposal-forge/ghcr-pull username='jaupole' password='<ghcr PAT>'

# (2e. minio/proposal-forge-files is written in step 3 after the bucket+key exist.)

# 2f. Publish the Keycloak client_secret from the KC DB → OpenBao
#     (secret/apps/proposal-forge/runtime#oidc_client_secret). Merge-style:
#     preserves the 2c fields. Mints its own admin-break-glass token, so it
#     does NOT need openbao-root-token-tmp. Idempotent (re-run safe).
bash ~/secforge/platform/components/05l-keycloak-secret-publish.sh
```

> **Rotate** the Gemini + GSA keys on cutover — the values currently in the
> docker-compose `.env` are considered exposed and must not be reused verbatim.

---

## 3. MinIO bucket + scoped key (mc admin)

Create the bucket the PF backend writes uploads/assets/exports to. Mirror the
member-hub-documents setup ([[project_member_hub_minio_openbao_followup]]):
versioned + SSE-S3, with a bucket-scoped service-account key.

```bash
# mc alias `local` = MinIO admin (root). Adjust to your alias.
mc mb --ignore-existing local/proposal-forge-files
mc version enable local/proposal-forge-files
mc encrypt set sse-s3 local/proposal-forge-files

# Bucket-scoped policy + a service account (access/secret key) limited to it.
cat > /tmp/pf-files-policy.json <<'JSON'
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow",
    "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket","s3:GetBucketLocation"],
    "Resource": ["arn:aws:s3:::proposal-forge-files","arn:aws:s3:::proposal-forge-files/*"] } ] }
JSON
mc admin policy create local proposal-forge-files-rw /tmp/pf-files-policy.json
# Generate a service account scoped to that policy; capture access/secret key.
mc admin user svcacct add local <minio-admin-user> --policy /tmp/pf-files-policy.json
rm -f /tmp/pf-files-policy.json

# Write the key to OpenBao (so VSO renders proposal-forge-files-minio).
B bao kv put secret/minio/proposal-forge-files access_key='<svcacct access key>' secret_key='<svcacct secret key>'
```

> `minio/cnpg/credentials` already exists (shared CNPG backup user) — PF's CNPG
> cluster reuses it. No new key for backups.

---

## 4. SpiceDB schema (additive, atomic)

`ecosystem-schema.zed` already contains `proposalapp/proposal` (+ `managerapp/*`);
the 12 validators pass (`bash platform/manifests/spicedb/tests/run.sh`). The live
write is **read → diff → write** so any unexpected drift surfaces before writing.
SpiceDB rejects a write that would drop a type with live relationships, so this is
fail-safe.

```bash
# zed against the cluster gRPC endpoint (TLS). PSK from the live Secret.
PSK=$(sudo -n kubectl get secret -n spicedb spicedb-config-vso -o jsonpath='{.data.preshared_key}' | base64 -d)
ZED="zed --endpoint spicedb.spicedb.svc.cluster.local:50051 --token $PSK"   # add --insecure / CA flags per the SpiceDB CR's grpc TLS

# Read live and diff. The ONLY delta should be the proposalapp (+ managerapp) adds.
$ZED schema read > /tmp/live-schema.zed
diff /tmp/live-schema.zed ~/secforge/platform/manifests/spicedb/ecosystem-schema.zed   # additive-only expected

# Write the validated schema.
$ZED schema write ~/secforge/platform/manifests/spicedb/ecosystem-schema.zed
```

If `zed` isn't on the box, run it from a one-shot pod with `authzed/zed:v1.0.0`
in the `spicedb` ns (matches the validator image).

---

## 5. Apply the VSO bindings → render Secrets

With steps 1–3 done, VSO can render all four Secrets. Apply via the envsubst
wrapper ([[project_secforge_apply_manifest_envsubst]] — never raw `kubectl apply`):

```bash
cd ~/secforge
sudo -n bash platform/lib/apply-manifest.sh platform/manifests/proposal-forge/04-vso-bindings.yaml
# Wait for the 4 Secrets to materialize:
sudo -n kubectl get secret -n proposal-forge \
  proposal-forge-app-secrets ghcr-pull-secret proposal-forge-files-minio cnpg-minio-credentials
```

If a Secret stays absent, check the VaultStaticSecret status — usually a missing
KV key or a vso-policy path gap.

---

## 6. CNPG cluster + object store + scheduled backup

```bash
sudo -n bash platform/lib/apply-manifest.sh \
  platform/manifests/proposal-forge/06-objectstore.yaml \
  platform/manifests/proposal-forge/02-cnpg-cluster.yaml \
  platform/manifests/proposal-forge/07-cnpg-scheduled-backup.yaml
# Wait for the primary to be ready (creates the proposal-forge-db-app Secret):
sudo -n kubectl get cluster -n proposal-forge proposal-forge-db -w
```

Owner role `proposal_forge` has **no BYPASSRLS** — `FORCE ROW LEVEL SECURITY`
in the migration applies to the app's own connection. Confirm the WAL archiver
is healthy (it needs `cnpg-minio-credentials` from step 5).

---

## 7. Migration Job (Prisma `migrate deploy`)

```bash
sudo -n bash platform/lib/apply-manifest.sh platform/manifests/proposal-forge/08-migration-job.yaml
sudo -n kubectl logs -n proposal-forge job/proposal-forge-migrate -f
# Expect: 2 migrations applied (ecosystem_org_rls + sessions). Then sanity-check RLS:
sudo -n kubectl exec -n proposal-forge proposal-forge-db-1 -- \
  psql -U proposal_forge -d proposal_forge -c \
  "SELECT count(*) FROM pg_tables t JOIN pg_class c ON c.relname=t.tablename WHERE c.relforcerowsecurity;"
# Expect ~28 force-RLS tables.
```

---

## 8. Deployment

```bash
sudo -n bash platform/lib/apply-manifest.sh platform/manifests/proposal-forge/09-deployment.yaml
sudo -n kubectl rollout status -n proposal-forge deploy/proposal-forge --timeout=180s
```

The image is cosign-signed, so Kyverno `verify-image-signatures` admits it. The
pod runs non-root 65532, read-only rootfs (writable `/tmp`, `HOME=/tmp` for
Chromium), `NODE_EXTRA_CA_CERTS` = the internal CA configmap (for Keycloak JWKS
over the in-cluster cert).

---

## 9. Control org + app activation + SpiceDB back-link

PF reads active-org context from Ecosystem Control. The operator's org must
exist and have `proposalapp` activated:

1. Portal admin (`https://admin.secforge.dev`): confirm the org exists (it does
   if you already use Control). If brand-new, the signup wizard creates the
   three-layer identity (KC Org + SpiceDB + control_db) — and remember the
   org→platform SpiceDB back-link ([[project_spicedb_org_platform_backlink]]).
2. **App Admin UI** → activate `proposalapp` for the org. This writes the
   `app:proposalapp_<orgId>` object + the org's admin/use grants in SpiceDB.
3. PF writes its own per-proposal tuples (`proposalapp/proposal:<id>#app@app:proposalapp_<orgId>`)
   at proposal-creation time — nothing to pre-seed.

---

## 10. Verify end-to-end (on the tailnet)

1. Add a hosts-file entry mapping `pf.secforge.dev` → the host's
   tailnet IP (same as the other admin hosts).
2. Browse `https://pf.secforge.dev` → redirected to Keycloak →
   passkey login → back to the app with active-org context.
3. Create a project/proposal; confirm it's scoped to your org (RLS) and that a
   second org can't see it. Confirm a SpiceDB-denied user gets 403.
4. Upload a document → lands in the `proposal-forge-files` bucket. Export a PDF →
   Chromium renders (validates the non-distroless image + writable `/tmp`).

---

## Decommission (after a clean soak)

- Stop/retire the docker-compose stack (standalone Passport/JWT + local Postgres
  + local file storage are all superseded).
- Update PLAN.md, the realm-to-app matrix, and the API security tracker
  ([[reference_api_security_tracker]]).
- Drop the dead client-side login / admin-user-management UI from PF.
