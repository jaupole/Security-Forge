# DR drill — Tier 1 KIND findings (2026-05-23)

> Local KIND-based dry-run of the realm-import + secret-injection codification.
> Validates the *codification correctness* of #57 / #59 / #60 / #61 against a
> truly fresh Keycloak. Does NOT exercise Tailscale / DNS / public TLS / GHCR /
> SPIFFE / Velero restore (Tier 2 territory).

## Outcome

✅ Codification works after fixing two real bugs the drill surfaced. Both fixes
have shipped to `main`.

## Findings

### 1. `passwordBlacklist(Pwdb_top-100000.txt)` is a hard prereq on the Keycloak image

**Symptom:** realm-import Job fails immediately with
`java.lang.IllegalArgumentException: Password blacklist Pwdb_top-100000.txt not found!`.

**Why:** Keycloak resolves the `passwordPolicy` declaration at server start.
If a `passwordBlacklist(<file>)` clause references a file that doesn't exist at
`/opt/keycloak/data/password-blacklists/`, the server refuses to start in
non-server (import) mode.

**Where the file comes from in prod:** the custom Keycloak image
(`ghcr.io/jaupole/keycloak:<tag>`) bakes the HIBP top-100000 file via the
Dockerfile at `platform/manifests/keycloak/image/Dockerfile`. Stock upstream
`quay.io/keycloak/keycloak` does NOT include it.

**Status:** documented but not changed. The platform-realm.yaml correctly
declares the blacklist; the dependency is on the IMAGE, not the realm
manifest. 03a-keycloak-realm-hardening.sh's header already notes this prereq.

**DR rebuild implication:** before applying `platform-realm.yaml` on a fresh
cluster, ensure the custom Keycloak image is in use AND the blacklist file is
baked into it. The GHA workflow `.github/workflows/keycloak-image-build.yml`
handles the bake; the cluster's Keycloak CR must reference the resulting
digest (see [keycloak-operations.md](./keycloak-operations.md)).

### 2. Client descriptions exceeded Keycloak's varchar(255) limit

**Symptom:** realm-import fails with PostgreSQL
`ERROR: value too long for type character varying(255)` on the `openbao` client
INSERT.

**Why:** Keycloak's `CLIENT.DESCRIPTION` column is `varchar(255)`. My codified
descriptions across 9 clients were 250-350+ chars because I'd written
multi-sentence explanations of secret-storage flow into them.

**Fix:** [commit `59e5bbb`](https://github.com/jaupole/Security-Forge/commit/59e5bbb)
— truncated each description to a single-line purpose statement (35-86 chars).
Detailed context preserved in YAML comments above each block (not subject to
the DB column limit).

**DR rebuild implication:** none — caught and fixed before any real rebuild.

## What was validated

After the two fixes:

- ✅ Realm-import job completed in 12s.
- ✅ All 9 custom clients created (openbao, grafana, wazuh-dashboard,
  control × 3, member-hub × 3).
- ✅ 3 service-account `USER_ENTITY` rows present with correct
  `service_account_client_link`.
- ✅ Custom `browser-webauthn-required` authentication flow + 4 nested
  subflows imported; realm's `browser_flow` correctly bound to it.
- ✅ WebAuthn policy fields applied: `RpId=drill.local` (via `${DOMAIN}`
  envsubst), `UV=required`, `attestation=none`, `signature_algs=ES256+RS256`.
- ✅ Operator auto-generated 32-char `client_secret` values for all 8
  confidential clients; `control-portal` has NULL (correctly — it's a
  PUBLIC client with PKCE).
- ✅ Drill-adapted 05l publish wrote every operator-generated secret to the
  expected OpenBao kv path / k8s Secret destination. End state verified:
  - `secret/apps/member-hub/runtime` → 3 keys (oidc, admin, system)
  - `secret/apps/control/runtime` → 2 keys (oidc, admin)
  - `secret/grafana/oidc` → 1 key (client_secret)
  - `secret/wazuh/oidc` → 5 keys (client_id, client_secret, cookie_password,
    issuer, redirect_uri)
  - `openbao/keycloak-openbao-client-secret` → client_secret

## What was NOT validated (Tier 2 territory)

- Cloudflare DNS A/AAAA + public TLS via cert-manager + Let's Encrypt
- Tailscale operator mesh
- Velero restore-from-MinIO
- GHCR pull with cosign signature verification (requires Kyverno + real PAT)
- SPIFFE/SPIRE workload-identity flow + spiffe-helper sidecar
- Wazuh / Loki / Tempo / Prometheus stack
- Actual Member Hub backend pod startup (depends on all of the above)

## Operator takeaways for an actual greenfield rebuild

0. **Enable k3s etcd Secrets-encryption BEFORE any workload deploys.** Append
   `secrets-encryption: true` to `/etc/rancher/k3s/config.yaml` (the platform
   tree at `platform/host/k3s/config.yaml` already includes it as of commit
   `e62a9bf`) and restart k3s before applying any manifests. **This is the
   step that's easy to skip and very costly to retrofit later** — if workloads
   accumulate Secrets before this is on, every Secret value (MinIO SSE master
   key, kopia passphrase, OpenBao seal token, ghcr-pull-secret PATs, every
   VSO-rendered value) sits plaintext in `state.db` until you rotate ALL of
   them. The 2026-05-28 audit traced multiple master keys this way via
   `strings state.db`. Verify post-restart:
   ```bash
   sudo k3s secrets-encrypt status
   # Encryption Status: Enabled
   ```
1. **Boot the custom Keycloak image first**, NOT stock upstream — otherwise
   the password-blacklist prereq fails.
2. **Run 03 + 03a as documented** — realm-import handles most of 03a now
   (commit `0ce2ace`), but 03a's stages [04]+[05] custom-flow path is folded
   in too (commit `17f4b92`). Verify post-import that browserFlow is bound.
3. **Run 05l-keycloak-secret-publish.sh AFTER realm-import** — it bridges the
   operator-generated secrets to the consumer destinations. Without it,
   apps fail auth.
   - **Roster update 2026-06-03:** `proposal-forge` (app `proposalapp`) was
     codified after this drill, so the realm now has **10** custom clients
     (**9** confidential). 05l publishes its secret to
     `secret/apps/proposal-forge/runtime#oidc_client_secret`. A future Tier 1
     re-drill should additionally expect
     `secret/apps/proposal-forge/runtime` → 1 key (`oidc_client_secret`). The
     remaining `proposal-forge/runtime` fields (`spicedb_psk`,
     `session_signing_key`, `gemini_api_key`, `gsa_api_key`) are operator-
     populated, NOT published by 05l — see
     [proposal-forge-deploy.md](proposal-forge-deploy.md) step 2.
4. **Cluster-rebuild ordering matters**:
   `k3s+secrets-encryption → kube → cnpg → vso → openbao operator+CR+05c+05j → keycloak operator+CR+realm-import → 05l → app deploys`.
   The new ordering puts 05l AFTER realm-import, which is different from
   pre-#60 docs.
5. **Populate three OpenBao paths that don't live in any bootstrap script** — these are
   operator-driven population steps surfaced during the 2026-05-28 audit:
   - `secret/data/apps/control/qbo` — needs `client_id` + `client_secret`
     fields with the Intuit QuickBooks Developer Portal app credentials.
     Without this, `control-qbo-secrets` VSS stays SYNCED=False (harmless,
     `envFrom` is `optional: true`). See [quickbooks-online-setup.md](./quickbooks-online-setup.md).
   - `secret/data/minio/member-hub-documents` — needs `access_key` +
     `secret_key` for the MinIO service account scoped to the
     `member-hub-documents` bucket. Created during 09f or generated on-demand;
     stash the values in OpenBao after the bucket + service-account exist.
   - `secret/data/platform/minio/sse-master-key` — auto-populated by 09f
     (`platform/components/09f-minio-sse-encryption.sh`) on first run, but if
     the SSE master key has been rotated post-bootstrap (as 2026-05-28),
     verify the **current** key name + bytes are in OpenBao at the latest kv-v2
     version. See [minio-sse-rotation.md](./minio-sse-rotation.md).
6. **VSO `destination.overwrite: true`** for any VSS whose target K8s Secret
   was created manually (not by VSO itself). Without it VSO sees the existing
   Secret and refuses to manage it, leaving SYNCED=False forever. Surfaced
   2026-05-28 on `member-hub-documents-minio-vso`.

## Bugs caught + fixed

| | Bug | Fix |
|---|---|---|
| 1 | Realm-level passwordPolicy depends on Pwdb file in image — not a bug per se, but undocumented for fresh-image scenarios | Documented in this runbook + 03a header already mentions it |
| 2 | Client descriptions >255 chars break realm-import | Commit `59e5bbb` truncated all 9 |

## Cleanup

```bash
kind delete cluster --name sf-dr
```


## See also — faster same-host datastore rollback (#95)

For datastore corruption or a bad bulk change that does NOT need a full greenfield rebuild,
there is now a 6-hourly online SQLite snapshot of `state.db` in MinIO (bucket
`k3s-datastore-backups`, SSE-S3, ~6h RPO) — restore it in place per
[`k3s-datastore-restore.md`](./k3s-datastore-restore.md). The full rebuild + Velero restore
documented above remains the path for full host loss (it also restores the secrets-encryption
key, which the datastore snapshot deliberately omits).
