# Runbook: Rotating the SPIRE Upstream CA

> **Production note.** Written for the local edition. In production the SPIRE trust domain is **`secforge.platform`** and the cluster is **Hetzner k3s** single node. Verify steps against the live cluster before acting. See [PLAN.md](../../PLAN.md).

**Frequency:** Every ~9 years (CA validity is 10y; rotate at least 6 months before expiry).
**Estimated duration:** 30 minutes including verification.
**Disruption:** brief — pods receive a fresh trust bundle on next SVID rotation. Plan for ~1h to fully propagate.
**Companion:** [docs/03-runbooks/spire-rotation.md](./spire-rotation.md) for SVID-level rotation issues; [ADR-0005](../02-decisions/0005-spire-architecture-local.md) for why this CA is on disk-as-Secret in the first place.

> The current root CA was issued **2026-04-29** with subject `CN=SecForge Local SPIRE Root CA`, key type **ECDSA P-256**. It is valid until **2036-04-26**. SHA-256 fingerprint: `EA:A6:A7:31:F2:FA:21:A3:D0:1F:DC:00:8D:EE:BE:21:B7:15:6E:0F:41:14:AF:53:A1:9C:5C:D0:6D:67:31:06`.
>
> Update the dates, key type, and fingerprint in this paragraph **after** every rotation.
>
> **Algorithm constraint:** SPIRE's `disk` UpstreamAuthority plugin (verified on 1.14.5) does **not** support Ed25519 root keys — it returns `unsupported private key type ed25519.PrivateKey` and crashloops the spire-server. Use ECDSA (`prime256v1` / P-256) or RSA-2048+ for the root key.

---

## When to rotate

- **Scheduled:** when the existing CA has < 12 months of validity remaining.
- **Unscheduled / emergency:** if the CA private key is suspected compromised — note: locally this means "your laptop was compromised," because the key has only ever lived in the cluster Secret since generation. Treat as a full incident.
- **After significant SPIRE upgrades** that change the supported algorithm set (e.g., if Ed25519 ever becomes deprecated, which is unlikely in this decade).

## What you'll need

- Cluster context pointing at the local Docker Desktop K8s.
- `openssl`, `kubectl`, `shred`.
- `helm` (only needed if you also want to roll spire-server during the rotation).

## Approach

SPIRE's `disk` UpstreamAuthority plugin reads the upstream cert+key on every CA mint. We replace the Secret in place, then trigger spire-server to mint a fresh intermediate from the new upstream. SPIRE's bundle-rotation logic propagates the new trust anchor to agents, which propagate it to workloads.

There are two safe ways to do this:

- **Option A — atomic swap:** generate the new CA materials, replace the Secret, restart spire-server. New SVIDs are issued from the new chain immediately; old SVIDs continue to validate against the old root *only* if you keep both roots in the bundle during the overlap window. SPIRE supports bundle-prepended rotation; not all consumers do. Use this for emergencies.
- **Option B — overlap rotation (preferred):** prepend the new root to the bundle; keep both roots in circulation until all SVIDs minted under the old root expire (1h with our TTL); then remove the old root. Zero downtime.

This runbook describes Option B.

---

## Step 1 — Generate the new upstream CA

```bash
mkdir -p /tmp/spire-ca-rotate && cd /tmp/spire-ca-rotate
openssl genpkey -algorithm Ed25519 -out root-ca-new.key
openssl req -new -x509 -days 3650 -key root-ca-new.key \
  -subj "/CN=SecForge Local SPIRE Root CA" \
  -out root-ca-new.crt
openssl x509 -in root-ca-new.crt -noout -fingerprint -sha256
```

Record the fingerprint somewhere durable. You will paste it into the runbook header (above) and the architecture doc once rotation completes.

## Step 2 — Stage the new Secret alongside the old one

```bash
kubectl create secret generic spire-upstream-ca-new \
  --namespace=spire \
  --from-file=tls.key=/tmp/spire-ca-rotate/root-ca-new.key \
  --from-file=tls.crt=/tmp/spire-ca-rotate/root-ca-new.crt
```

> The Secret keys must be `tls.crt` and `tls.key` — that's what the Helm chart's `upstreamAuthority.disk` plugin mounts at `/run/spire/upstream_ca/tls.{crt,key}`. Don't use other key names; they won't be picked up.

Don't delete the old Secret yet.

## Step 3 — Pre-pend the new root to SPIRE's trust bundle

This makes the new root trusted by every agent and workload **before** spire-server starts minting under it.

```bash
NEW_BUNDLE=$(cat /tmp/spire-ca-rotate/root-ca-new.crt)
kubectl exec -n spire statefulset/spire-server -- /opt/spire/bin/spire-server bundle set \
  -id spiffe://secforge.platform \
  -path /dev/stdin <<<"$NEW_BUNDLE"
```

Wait ≥ 5 minutes for the bundle update to propagate to all agents. Verify:

```bash
kubectl exec -n spire daemonset/spire-agent -- ls /run/spire/agent-sockets/ # sanity
kubectl exec -n spire statefulset/spire-server -- /opt/spire/bin/spire-server bundle show
```

## Step 4 — Switch spire-server to mint under the new root

```bash
kubectl patch statefulset spire-server -n spire \
  --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes","value":[ ... use spire-upstream-ca-new ... ]}]'
```

The exact patch depends on whether the deployment is templated by Helm (preferred). If managed by Helm, edit `platform/values/spire.yaml` to point the volume `secretName` at `spire-upstream-ca-new` and run:

```bash
helm upgrade spire spiffe/spire -n spire -f platform/values/spire.yaml
```

Wait for spire-server to come back up. Check that newly issued SVIDs now have the new root in their chain:

```bash
kubectl delete pod -n test-spire -l app=spiffe-test  # force a fresh issuance
kubectl logs -n test-spire -l app=spiffe-test
# Issuer should report: CN = SecForge Local SPIRE Root CA, fingerprint = <new>
```

## Step 5 — Wait one full SVID TTL + buffer

With our 1h X.509 TTL, wait 90 minutes. After this window, no live SVID is signed by the old root.

## Step 6 — Remove the old root from the bundle

```bash
OLD_FINGERPRINT="<paste old SHA-256 fingerprint>"
kubectl exec -n spire statefulset/spire-server -- /opt/spire/bin/spire-server bundle list
# Identify and remove the old bundle entry; the exact CLI invocation depends on
# SPIRE version. As of 1.14.x:
kubectl exec -n spire statefulset/spire-server -- /opt/spire/bin/spire-server bundle delete \
  -id "spiffe://secforge.platform"
# (if 'bundle delete' is not appropriate, prune via 'bundle set' replacing the bundle
#  with new-only contents)
```

## Step 7 — Delete the old Secret

```bash
kubectl delete secret -n spire spire-upstream-ca
kubectl get secret -n spire spire-upstream-ca-new -o yaml \
  | sed 's/spire-upstream-ca-new/spire-upstream-ca/' \
  | kubectl apply -f -
kubectl delete secret -n spire spire-upstream-ca-new
```

(After this the canonical Secret name is again `spire-upstream-ca`, so values files and rotation #N+1 don't accumulate suffixes.)

## Step 8 — Shred the local files

```bash
shred -u /tmp/spire-ca-rotate/root-ca-new.key
rm /tmp/spire-ca-rotate/root-ca-new.crt
rmdir /tmp/spire-ca-rotate
```

## Step 9 — Update documentation

- Update the header of this runbook with the new dates and fingerprint.
- Update [docs/01-architecture/06-workload-identity.md](../01-architecture/06-workload-identity.md) if the algorithm or validity changed.
- Add a one-line "Rotated CA on YYYY-MM-DD" entry to [ADR-0005](../02-decisions/0005-spire-architecture-local.md) under a `## Rotation history` section.

---

## Recovery: I deleted the upstream CA Secret by mistake

If the Secret is gone but the old materials are also gone (you shredded the local copy), spire-server cannot reissue and you must bootstrap from scratch:

1. Generate a new CA (Step 1).
2. Recreate the Secret with the canonical name.
3. Wipe the spire-server data PVC: `kubectl delete pvc -n spire spire-server-data-0`.
4. Restart spire-server. It will re-mint everything from the new root.
5. **Every workload** will receive a new chain that doesn't validate against any cached old root, but since this is the local edition and there are no off-cluster verifiers, the blast radius is bounded.
6. Update fingerprint in this runbook header.

## Recovery: spire-server can't read the Secret (permissions, mount path)

Check:

- `kubectl describe pod -n spire -l app.kubernetes.io/component=server` — look for volume-mount failures.
- The Secret has both `tls.key` and `tls.crt` data fields:
  `kubectl get secret -n spire spire-upstream-ca -o jsonpath='{.data}'` should return JSON with both keys.
- The pod's ServiceAccount has Secret read permissions:
  `kubectl auth can-i get secrets/spire-upstream-ca --namespace spire --as system:serviceaccount:spire:spire-server`
- The volume mount in the spire-server StatefulSet matches what `server.conf` expects (`/run/spire/upstream_ca/tls.crt` and `.../tls.key`).

## What if the CA private key was compromised

Treat as a full incident:

1. Pause all CI/CD that runs against this cluster.
2. Run **Option A (atomic swap)** rotation immediately — do not preserve the compromised root in the bundle.
3. Rotate every long-lived secret in OpenBao that an attacker holding the SPIRE root could have issued itself credentials for.
4. Audit `kubectl get events -A` and SPIRE server logs for unexpected registrations.
5. Document the incident in `docs/03-runbooks/incidents/YYYY-MM-DD-spire-root-compromise.md`.
