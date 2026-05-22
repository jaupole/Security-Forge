# SecForge custom Keycloak image

Produces `ghcr.io/jaupole/keycloak@sha256:<digest>` — an overlay of the
upstream Keycloak base with:

1. **HIBP top-100k password blacklist** baked at
   `/opt/keycloak/data/password-blacklists/Pwdb_top-100000.txt` so the
   realm's `passwordBlacklist(Pwdb_top-100000.txt)` policy resolves on
   any cluster, including a cold-start DR rebuild — without needing a
   ConfigMap mount or an init container.
2. **Optimized build** via `kc.sh build --features=recovery-codes,dpop --db=postgres`
   so the runtime pod starts with `--optimized` (no per-start Quarkus
   re-augmentation, no writable rootfs requirement).

Build + sign happens in GitHub Actions; see
`.github/workflows/keycloak-image-build.yml`. The cluster's
`verify-image-signature` Kyverno policy verifies the signature against
the GitHub Actions OIDC issuer + this repo's identity regex.

## Refreshing the upstream Keycloak base

1. Resolve the new base digest:
   ```bash
   docker pull quay.io/keycloak/keycloak:<new-version>
   docker inspect quay.io/keycloak/keycloak:<new-version> --format '{{.RepoDigests}}'
   ```
2. Edit `Dockerfile` — bump `KEYCLOAK_BASE_DIGEST`.
3. PR. GHA builds + signs. Merge.
4. Bump `platform/manifests/keycloak/04-keycloak-cr.yaml` `spec.image` to
   the new `ghcr.io/jaupole/keycloak@sha256:<built-digest>` (digest is
   in the GHA run summary).
5. `kubectl apply` the CR. Operator handles the rollout.

Renovate's regex manager watches `KEYCLOAK_BASE_DIGEST` (see
`renovate.json` at repo root, when added) and opens a PR automatically.

## Refreshing the HIBP blacklist

The list itself is curated by danielmiessler/SecLists (annual cadence).
To update:

1. Find the current HEAD commit of SecLists master:
   ```bash
   git ls-remote https://github.com/danielmiessler/SecLists.git refs/heads/master
   ```
2. Verify the file at that commit:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/danielmiessler/SecLists/<new-commit>/Passwords/Common-Credentials/Pwdb_top-100000.txt -o /tmp/pwdb.txt
   sha256sum /tmp/pwdb.txt
   ```
3. Edit `Dockerfile` — bump `PWDB_COMMIT` and `PWDB_SHA256`.
4. PR + merge → GHA builds + signs.

The `--checksum=sha256:` in the Dockerfile's `ADD` instruction fails the
build immediately if the bytes ever change without an explicit SHA bump.
Tamper-evident by construction.

## Local build (for testing only)

```bash
# Requires Docker Buildx ≥ 0.10 (for ADD --checksum support)
docker buildx build \
  --platform linux/amd64 \
  --tag ghcr.io/jaupole/keycloak:local-test \
  --load \
  platform/manifests/keycloak/image/
```

**Do not** push locally-built images to ghcr — they won't carry the
Cosign signature the cluster requires. Always go through GHA for prod.

## Why this image + not a ConfigMap-mounted blacklist

The previous pattern mounted the blacklist via the
`keycloak-password-blacklist` ConfigMap (~810 KB, well under the 1 MiB
limit) and a `volumeMount` patched into the Keycloak CR. That works but
adds two failure modes:

1. CM not present at pod start → realm passwordPolicy evaluation throws
   on the first password operation (sign-in / reset / register)
2. Operator-managed StatefulSet may revert the volume mount on chart
   upgrade or reconcile pass

Baking into the image makes the file's presence a structural invariant
of the running pod. There's nothing for the operator to drop, nothing
for kubectl to forget, and the file shows up in the image SBOM (Trivy
tracks it like any other layer artifact).

After the first signed image is built + deployed, the
`keycloak-password-blacklist` ConfigMap can be removed (see
`docs/03-runbooks/keycloak-realm-hardening-replay.md`).
