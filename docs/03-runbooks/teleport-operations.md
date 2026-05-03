# Teleport operations (local edition)

> Daily ops for the local Teleport deployment. The "why" is in [ADR-0024](../02-decisions/0024-teleport-community-edition-local.md); this doc is the muscle memory.

## Cluster shape

| Component | Where |
|---|---|
| Auth + Proxy | `teleport` ns, `teleport-cluster` Helm release (chart 18.7.6, `chartMode: standalone`) |
| Backend | PVC-backed sqlite on the auth pod (NOT the CNPG `secforge-teleport-db` cluster — that's reserved for HA promotion, currently unused) |
| Operator | `teleport-operator` deployment in the same ns; reconciles `TeleportRoleV7` + `TeleportGithubConnector` CRs |
| Public hostname | `tp.secforge.local:8443` (operator port-forward `svc/teleport 8443:443`) |
| TLS | mkcert local CA, issued by cert-manager (`tp-secforge-local-tls` Secret) |
| Session recording | MinIO bucket `teleport-recordings`, scoped MinIO user `teleport-sessions`, creds at OpenBao `secret/data/minio/teleport/credentials` |
| Audit log | sqlite + structured-JSON stdout (Promtail → Loki ingestion to come; Wazuh forwarding deferred) |
| SSO | GitHub OAuth (CE has no OIDC — see ADR-0024 § Amendment 2026-05-03) |
| MFA | Github.com user-side factor (operator should enable TOTP on their account); compensating control = tightened session TTLs |

## Daily operator flow

These are the commands an admin runs to do anything privileged.

### 1. Start the port-forward

```
kubectl port-forward -n teleport svc/teleport 8443:443
```

Leave it running in a dedicated terminal. **The forward dies on cluster restart, on Docker Desktop sleep, and sometimes mid-session under sustained traffic.** If you see `connection refused` on `tp.secforge.local:8443` from any tsh command, restart the forward first. A loop wrapper helps:

```
while true; do kubectl port-forward -n teleport svc/teleport 8443:443; sleep 2; done
```

### 2. Login

```
tsh login --proxy=tp.secforge.local:8443 --auth=github
```

Browser opens (or copy-paste the printed `http://127.0.0.1:<random>/<uuid>` link if WSL can't auto-open). GitHub OAuth → consent → callback → tsh prints profile summary.

Expected: `Logged in as: <github-username>`, `Roles: admin` (if you're in `security-forge1:platform-admins`), `Valid until: <8h from now>`, `Kubernetes: enabled`, `Kubernetes groups: system:masters`.

### 3. Get a kubeconfig

```
tsh kube login secforge-local
```

**Side effect**: this rewrites your shell's current `~/.kube/config` context to `secforge-local-secforge-local`. Other shells that source `~/.kube/config` are also affected. If you need an isolated kubeconfig (e.g., to keep direct cluster access in another shell), do this first:

```
export KUBECONFIG=~/.kube/teleport-secforge.config
tsh kube login secforge-local
```

To switch back to direct cluster access in the same shell:

```
kubectl config use-context docker-desktop
```

### 4. Use kubectl

```
kubectl get pods -A      # routed via Teleport
kubectl exec -it -n <ns> <pod> -- bash
```

Interactive sessions are recorded automatically.

### 5. Logout

```
tsh logout
```

Clears local certs. The Teleport-side session continues until its TTL.

## Bootstrap (one-time setup)

Reproduces the steps Phase 8b prototype B used. Skip on existing installs.

### 5a. GitHub OAuth App (manual, github.com side)

1. **Create the OAuth App.** Settings → Developer settings → OAuth Apps → "New OAuth App".
   - Application name: `SecForge Local Teleport` (or any label).
   - Homepage URL: `https://tp.secforge.local:8443`.
   - Authorization callback URL: `https://tp.secforge.local:8443/v1/webapi/github/callback`.
2. **Generate a client secret** — shown ONCE. Copy immediately.
3. **Authorize the OAuth App against the org.** This is the easy-to-miss step that produces a confusing first-login error. On orgs created after ~2020, OAuth Apps need org-level approval to read team membership. Go to:
   ```
   https://github.com/organizations/<your-org>/settings/oauth_application_policy
   ```
   and grant the app access. Without this, the first `tsh login --auth=github` succeeds at GitHub but Teleport's connector returns `"list of user teams is empty, did you grant access?"`.

### 5b. Wire the connector into Teleport

```
BAO_TOKEN=$(bao login -method=oidc role=admin -format=json | jq -r .auth.client_token)
infrastructure/teleport/apply-github-connector.sh \
    <client_id> <client_secret> <org-slug> <team-slug>
```

The script writes the credentials to OpenBao at `secret/data/teleport/github`, waits for VSO to render `teleport-github-vso` in the `teleport` ns, substitutes the org/team/client_id placeholders into `06-github-connector.yaml`, applies the CR, and waits for the operator to confirm reconciliation.

### 5c. (Optional) Verify role mapping

```
tsh login --proxy=tp.secforge.local:8443 --auth=github   # someone in the mapped team
tsh status   # should show Roles: admin
```

## Verifying session recording

Every interactive session (`kubectl exec -it`, `tsh ssh`, etc.) generates a recording. To confirm a specific session landed:

1. Find the session ID in the auth log:
   ```
   kubectl logs -n teleport deploy/teleport-auth --tail=200 \
       | grep -E '"event_type":"session\.(start|end)"'
   ```
   Each event has a `sid` field (UUID). The `session.end` event also has `session_start` / `session_stop` timestamps and the user.
2. Confirm upload to MinIO:
   ```
   kubectl exec -n minio deploy/minio -- env \
       MC_HOST_local="http://$(kubectl get secret -n minio minio-root-credentials -o jsonpath='{.data.rootUser}' | base64 -d):$(kubectl get secret -n minio minio-root-credentials -o jsonpath='{.data.rootPassword}' | base64 -d)@localhost:9000" \
       mc ls local/teleport-recordings/ | grep <sid>
   ```
   You should see three files: `<sid>.tar` (the recording), `<sid>.metadata`, `<sid>.thumbnail`.
3. Replay:
   ```
   tsh play <sid>
   ```
   Or via the Teleport web UI → Audit → Session Recordings.

The audit pipeline is independent of the `kubectl port-forward` — even if the forward dies during a session, the auth pod will finalize and upload the recording from inside the cluster.

## Troubleshooting

### `tsh login` succeeds in browser, then CLI errors with `dial tcp 127.0.0.1:3023: connection refused`

The proxy is in `proxy_listener_mode: separate` and tsh CLI is trying to dial the SSH proxy port that we don't forward. Fix: confirm `auth.teleportConfig.auth_service.proxy_listener_mode: multiplex` is set in `infrastructure/teleport/03-helm-values.yaml` and the change has been applied (`helm get values teleport -n teleport | grep -A1 auth_service`). If a `kubectl delete cluster_networking_config` was run somewhere, the dynamic-resource override is gone too — the static config will recreate it on the next auth-pod restart, but in the meantime you can re-set it:

```
cat <<EOF | kubectl exec -n teleport -i deploy/teleport-auth -- tctl create -f -
kind: cluster_networking_config
version: v2
metadata:
  name: cluster-networking-config
spec:
  proxy_listener_mode: 1
EOF
```

(`1` = multiplex; the protobuf enum doesn't accept the `multiplex` string in the dynamic resource API even though it does in static config — Teleport quirk.)

### `tsh login` fails with `list of user teams is empty, did you grant access?`

GitHub OAuth App lacks org-level approval. See § 5a step 3.

### `tsh login` succeeds but `tsh status` shows `Roles:` empty (no admin)

Your GitHub user isn't in the team that maps to a role. Check:
- The `TeleportGithubConnector/github` CR's `teams_to_roles` lists `<your-org>:<your-team>`.
- You're an active member of that team on github.com (`https://github.com/orgs/<org>/teams/<team>/members`).
- The GitHub OAuth App is authorized against that org (5a step 3).

### `kubectl get pods` after `tsh kube login` returns `connection refused`

The port-forward died. Restart it. Note: `tsh kube login` rewrote your shell's kubectl context, so even commands you used to run pre-Teleport are now routed through Teleport. To recover direct access immediately: `kubectl config use-context docker-desktop`.

### `helm upgrade` for the teleport release hangs on `--wait`

Docker Desktop's `cloud-provider-kind` keeps trying to provision a LoadBalancer external IP for `svc/teleport` (chart default service type) and failing on Docker container creation. helm `--wait` *shouldn't* block on this (it waits for ClusterIP allocation, not external IP) but in practice the upgrade can hang the full `--timeout` and end in `failed` state. Recovery:

```
helm upgrade teleport teleport/teleport-cluster --namespace teleport --version 18.7.6 \
    -f infrastructure/teleport/03-helm-values.yaml --timeout=2m
```

(no `--wait`). The release flips to `deployed` and the apply is idempotent.

### Auth pod crashlooping after a Docker Desktop restart

Same root cause as every other pod here: stale SVID, OpenBao still sealed, or PVC remount race. Walk the standard recovery: unseal OpenBao first (`infrastructure/openbao/unseal-seal.sh`), then `kubectl delete pod -n teleport teleport-auth-<hash>`. The CNPG `secforge-teleport-db-1` pod must be Running before the auth pod can come up cleanly even though we don't currently use Postgres as the backend (the chart still wants the DB resource Ready as a perceived dependency).

## Known gaps and follow-ups

These are accepted-and-tracked, not bugs to fix today. See ADR-0024 § Known gaps for the rationale.

1. **`admin` role grants `kubernetes_groups: [system:masters]`.** Full cluster-admin equivalence via Teleport. The plan is to scope this down to a real `ClusterRole` with explicit verbs at the same trigger that removes the operator's direct kubeconfig (cloud cutover or second operator joins).
2. **No MinIO Object Lock** on `teleport-recordings`. A compromised admin can delete their own recording. Cloud cutover gets S3 Object Lock.
3. **No Wazuh-side audit log forwarding.** Teleport's structured-JSON audit events live in the auth pod's stdout (Promtail → Loki ingestion is fine for query) but aren't yet forwarded to Wazuh as a SIEM-source. Tracked separately (Phase 7d follow-up).
4. **Single-replica auth+proxy.** Loss of the auth pod = no Teleport logins until it recovers (~1min on Docker Desktop). Operator falls back to direct kubeconfig (`KUBECONFIG=~/.kube/config kubectl config use-context docker-desktop`). Production removes that fallback.
5. **OAuth App credentials live in OpenBao but the GitHub-side secret is governed only by github.com's policies.** Rotating them is a manual two-step (regenerate at github.com, re-run `apply-github-connector.sh` with the new value).

## Related runbooks + ADRs

- [ADR-0024 — Teleport CE for privileged access](../02-decisions/0024-teleport-community-edition-local.md) — the why for every choice in this runbook, plus the cloud-edition cutover trigger to restore Keycloak OIDC.
- [ADR-0007 — TOTP instead of passkeys (locally)](../02-decisions/0007-totp-instead-of-passkeys-locally.md) — explains why the platform-wide MFA posture is TOTP-via-Keycloak and where Teleport diverges (GitHub-side factor instead of Keycloak-side).
- [docs/03-runbooks/openbao-seal-unseal.md](./openbao-seal-unseal.md) — the auth-pod-crashlooping recovery flow above depends on this running first.
- [docs/03-runbooks/keycloak-operations.md](./keycloak-operations.md) — relevant when cloud cutover swaps the GitHub connector for the Keycloak OIDC one.
