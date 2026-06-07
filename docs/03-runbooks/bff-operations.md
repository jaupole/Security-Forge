# BFF Operations Runbook

> **Production note.** Written for the local edition. In production: the cluster is **Hetzner k3s** single node (a "Docker Desktop restart" = a **node reboot**); ingress is the **Istio gateway** (not ingress-nginx); operator access is the **Tailscale tailnet**; the SPIRE trust domain is **`secforge.platform`**. Verify steps against the live cluster before acting. See [PLAN.md](../../PLAN.md).

> Architecture: [docs/01-architecture/04-bff-pattern.md](../01-architecture/04-bff-pattern.md)
> ADRs: [0011 — single replica](../02-decisions/0011-bff-single-replica-local.md), [0015 — secret distribution](../02-decisions/0015-secret-distribution-pattern.md)
> Implementation: [apps/helloworld-bff/](../../apps/helloworld-bff/)

---

## What this runbook covers

The local-edition Hello World BFF (`apps/helloworld-bff/`), single-replica
Deployment in the `app` namespace. Same patterns will apply to
`proposal-forge-bff`, `project-tracker-bff`, `pm-bff` once they are
deployed (Phases 9–11).

What's NOT here: the design rationale (in `04-bff-pattern.md`), the
secret-distribution shape (in `05-secrets-management.md` + ADR-0015),
the full code organization (read the source).

---

## Reach the cluster

All commands assume:
- `kubectl` on PATH, default context = Docker Desktop K8s
- The BFF Deployment `helloworld-bff` exists in `app` namespace
- Private signing key is in OpenBao at
  `secret/data/keycloak/clients/helloworld-bff` (read direct-API by
  the BFF via SPIFFE-bound JWT — no K8s Secret intermediate, see ADR-0015)

```bash
# Default landing checks
kubectl get deploy/helloworld-bff -n app
kubectl get pod -n app -l app.kubernetes.io/name=helloworld-bff
```

The BFF listens on port 3000 inside the pod. External traffic enters
via ingress-nginx at `https://hello.secforge.dev`. For ad-hoc local
testing without going through ingress, port-forward:

```bash
kubectl -n app port-forward deploy/helloworld-bff 13000:3000
# Then: http://localhost:13000/healthz, /ready, /login, etc.
```

---

## Routine operations

### Tail logs

```bash
# Main BFF process
kubectl -n app logs deploy/helloworld-bff -f

# spiffe-helper init container (only useful on pod start; this fetches
# the JWT-SVID used to authenticate to OpenBao for the private_key_jwt
# bootstrap)
kubectl -n app logs deploy/helloworld-bff -c spiffe-helper
```

The BFF emits JSON logs. Filter by level:

```bash
kubectl -n app logs deploy/helloworld-bff --tail=200 | jq 'select(.level=="ERROR")'
```

### Health probes

```bash
kubectl -n app port-forward deploy/helloworld-bff 13000:3000 >/dev/null &
PF=$!; sleep 2

curl -sS -w '\nstatus: %{http_code}\n' http://localhost:13000/healthz
# expect: status 200, body {"ok":true}

curl -sS -w '\nstatus: %{http_code}\n' http://localhost:13000/ready
# expect: status 200 if Valkey + OpenBao + Keycloak JWKS reachable;
# 503 with body containing the failing dep otherwise.

kill $PF; wait 2>/dev/null
```

### Restart the BFF

```bash
kubectl -n app rollout restart deployment/helloworld-bff
kubectl -n app rollout status deployment/helloworld-bff --timeout=120s
```

A restart triggers:
1. spiffe-helper init container re-fetches a JWT-SVID for `spiffe://secforge.platform/ns/app/sa/helloworld-bff`.
2. Main container reads `secret/data/keycloak/clients/helloworld-bff` from OpenBao using the SVID.
3. Generates a fresh per-pod ECDSA P-256 DPoP keypair (in memory only).
4. Starts the HTTP server on :3000.

**Cookie consequence**: every existing user session whose DPoP `cnf.jkt`
was bound to the old pod's keypair is invalidated. Users have to log
in again. This is by design (per-pod DPoP key, ADR-0011) and is one
reason the BFF is single-replica locally — restart blast radius is
all-or-nothing.

### Verify login flow (smoke test)

```bash
kubectl -n app port-forward deploy/helloworld-bff 13000:3000 >/dev/null &
PF=$!; sleep 2

# Should return 302 to Keycloak with PAR request_uri:
curl -sS -I http://localhost:13000/login | grep -iE '^HTTP|^location:'

kill $PF; wait 2>/dev/null
```

Expected:
- `HTTP/1.1 302 Found`
- `Location: https://auth.secforge.dev/realms/secforge-tenants/protocol/openid-connect/auth?client_id=helloworld-bff&request_uri=urn%3Aietf%3Aparams%3Aoauth%3Arequest_uri%3A<UUID>`

If the `request_uri` parameter is missing, the BFF could not call
Keycloak's PAR endpoint — most likely cause is OpenBao or Keycloak
unreachable at startup (BFF should have failed `/ready`).

---

## Common failure modes

### "Pod stuck in Init or CrashLoopBackOff after restart"

Root cause is almost always one of:
- spiffe-helper can't reach SPIRE (cold-boot CSI race, see PLAN.md follow-up #6)
- spiffe-helper can reach SPIRE but workload registration is missing
- Main container can reach OpenBao but the `vso`/SPIFFE policy doesn't
  grant `read` on `secret/data/keycloak/clients/helloworld-bff`

Diagnose:

```bash
kubectl -n app describe pod -l app.kubernetes.io/name=helloworld-bff | tail -40
kubectl -n app logs <pod> -c spiffe-helper --previous 2>&1 | tail -30
kubectl -n app logs <pod>                  --previous 2>&1 | tail -30
```

Common fixes:
- **CSI race after Docker Desktop restart**: `kubectl delete pod` to
  let the scheduler retry. Tracked in PLAN.md Phase 5 follow-up.
- **Missing SPIFFE registration**: re-run
  `infrastructure/spire/apply-server.sh` and check the operator logs
  in `spire` namespace.
- **OpenBao policy denial**: check `bao policy read helloworld-bff`
  inside the openbao pod. Should grant `read` on
  `secret/data/keycloak/clients/helloworld-bff`. Source of truth:
  `infrastructure/openbao/policies/helloworld-bff.hcl`.

### "/ready returns 503"

Body indicates which dependency is failing. Re-check from the BFF's
network position:

```bash
# OpenBao reachability (from inside the BFF pod)
kubectl -n app exec deploy/helloworld-bff -- /bff -openbao-probe
# (if -openbao-probe isn't implemented, port-forward to OpenBao directly)

# Keycloak JWKS reachability
kubectl -n app exec deploy/helloworld-bff -- wget -qO- https://auth.secforge.dev/realms/secforge-tenants/protocol/openid-connect/certs

# Valkey reachability
kubectl -n valkey port-forward svc/valkey-primary 6379:6379 &
redis-cli -h localhost ping
```

### "DPoP htu mismatch" (401 from /api/* despite valid login)

Per `04-bff-pattern.md` §"htu canonicalization rule": the BFF builds
`htu` from `X-Forwarded-Proto + X-Forwarded-Host + path`. If any of
these don't match what the backend expects, validation fails 401.

Check ingress-nginx forwarded headers:
```bash
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller | grep -i "x-forwarded"
```

If `X-Forwarded-Proto` or `X-Forwarded-Host` is missing, the BFF
returns 400 with `{"error":"missing_forwarded_headers"}` (fail-closed
by design — see `04-bff-pattern.md`).

### "Login redirects me to Keycloak but bounces back with `error=invalid_request`"

PAR was rejected by Keycloak. Common causes:
- BFF's private_key_jwt signing key doesn't match Keycloak's
  registered public key for `helloworld-bff` client. After 6.10b
  the key lives in OpenBao at
  `secret/data/keycloak/clients/helloworld-bff` (key
  `private_key_pem`). Check it matches the Keycloak client's JWKS.
- `redirect_uri` not registered against the Keycloak client. Edit
  via kcadm (or the Keycloak UI).

Diagnostic:
```bash
# Keycloak client config:
kubectl -n keycloak exec deploy/keycloak -- /opt/keycloak/bin/kcadm.sh \
  get clients -r secforge-tenants -q clientId=helloworld-bff

# OpenBao key:
kubectl -n openbao exec openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 \
  BAO_TOKEN="$BAO_TOKEN" bao kv get -mount=secret keycloak/clients/helloworld-bff
```

---

## Private-key rotation

**Not implemented locally.** Rotation runbook is a Phase 7 deliverable
per ADR-0015 §"Operational hand-offs to other phases" and PLAN.md
Phase 5 follow-up. Until then, the keypair is static — keep an eye
on the registration date in Keycloak (`client.creationDate`) for
audit purposes.

When implemented, the rotation flow will be:
1. Mint new ECDSA P-256 keypair.
2. Register new public key with Keycloak via kcadm-admin (additive,
   keep both old and new keys valid during grace).
3. Versioned write of new private key to OpenBao at
   `secret/data/keycloak/clients/helloworld-bff`.
4. Restart BFF — it picks up the new key on bootstrap.
5. After grace period, deregister the old public key from Keycloak.

---

## Cluster-state quick reference

| Resource | Namespace | Source-of-truth file |
|---|---|---|
| Deployment `helloworld-bff` | `app` | `apps/helloworld-bff/deploy/02-deployment.yaml` |
| Service `helloworld-bff` | `app` | `apps/helloworld-bff/deploy/03-service.yaml` |
| ServiceAccount `helloworld-bff` | `app` | `apps/helloworld-bff/deploy/01-serviceaccount.yaml` |
| Ingress (`hello.secforge.dev`) | `app` | `apps/helloworld-bff/deploy/06-ingress.yaml` |
| OpenBao private_key_jwt source | `openbao` | `secret/data/keycloak/clients/helloworld-bff` |
| OpenBao policy granting BFF reads | n/a | `infrastructure/openbao/policies/helloworld-bff.hcl` |
| SPIRE workload registration | `spire` | `infrastructure/spire/04-clusterspiffeids.yaml` |

---

## See also

- [ADR-0011 — BFF runs as a single replica in the local edition](../02-decisions/0011-bff-single-replica-local.md) — explains the cookie-invalidation-on-restart property.
- [ADR-0015 — Secret distribution pattern](../02-decisions/0015-secret-distribution-pattern.md) — explains why the BFF reads OpenBao directly instead of via VSO.
- [04-bff-pattern.md](../01-architecture/04-bff-pattern.md) — design rationale for cookies, sessions, DPoP, identity propagation.
- [05-secrets-management.md](../01-architecture/05-secrets-management.md) — cluster-wide secret-distribution architecture.
