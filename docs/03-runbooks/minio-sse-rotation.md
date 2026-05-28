# MinIO SSE-S3 master key rotation (drain-and-rotate)

> ADR: [docs/02-decisions/0031-minio-kes-for-sse-rotation.md](../02-decisions/0031-minio-kes-for-sse-rotation.md) — covers both designs (drain-and-rotate executed 2026-05-28; KES retained as fallback architecture).
> Cross-reference: [transit-key-rotation.md](./transit-key-rotation.md) for PII-field-level Transit rotation (a different concern).

This runbook covers rotation of the MinIO **bucket-level SSE-S3 master key** — the static-KMS key supplied via `MINIO_KMS_SECRET_KEY` that wraps every object's per-object data-encryption-key (DEK). The key lives in OpenBao at `secret/data/platform/minio/sse-master-key`; VSO renders it into K8s Secret `minio-kms-creds`; MinIO mounts it as the env var.

## When to use this runbook

| Trigger | Notes |
|---|---|
| Suspected master-key compromise | e.g. operator turnover, audit pressure, key value was logged/exposed |
| Routine hygiene rotation | Recommend annual at minimum once you have a steady process |
| After a state.db plaintext leak finding | The current pre-rotation key value may be in kine MVCC history; rotation makes that exposure a dead reference |

This runbook does **not** cover:
- PII field-level Transit rotation (see [transit-key-rotation.md](./transit-key-rotation.md))
- Velero kopia passphrase rotation (separate script `platform/components/09e-velero-rotate-passphrase.sh`)
- OpenBao seal transit token rotation (see [openbao-recovery.md § Rotate Transit unseal token](./openbao-recovery.md#rotate-the-transit-unseal-token))

## Why drain-and-rotate and not in-place rotation

MinIO's static-KMS mode supports exactly one master key — there is no in-place "rotate" primitive. Changing the master key value renders every existing object's DEK unwrappable; MinIO can no longer read the objects.

The supported in-place rotation primitive is `mc encrypt rotate`, but it requires **MinIO KES** (a separate sidecar key-encryption-service). KES is now archived upstream (`minio/kes` archived 2025-06-19) so deploying it commits to a frozen-codebase platform component. ADR-0031 captures both designs; drain-and-rotate is the chosen path for this rotation cycle and any subsequent one until the broader MinIO substrate decision (operator-backlog #56) lands.

## Pre-flight checklist

- [ ] OpenBao is unsealed + main openbao pods healthy (`bao status` from any main openbao pod returns `Sealed: false`)
- [ ] VSO operator is running (`kubectl -n vault-secrets-operator get deploy`)
- [ ] The break-glass admin token path on main openbao is working (see [openbao-recovery.md § Kubernetes auth break-glass](./openbao-recovery.md#kubernetes-auth-break-glass)) — required for the `bao kv put` in step 5
- [ ] You know which MinIO buckets hold **user-irreplaceable data** vs **regeneratable data**. Inventory today (2026-05-28 reference):
  - `member-hub-documents/` — real user-uploaded files; **drain before wipe**
  - `backups/cnpg/` — CNPG barman base + WAL; **regeneratable** via fresh base backup per cluster
  - `backups/velero/` — Velero K8s resource backups + (after a Velero rotation) kopia PV backups; **regeneratable** via on-demand Velero Backup
  - `backups/sse-verify/` — empty test prefix; wipe
  - `loki-chunks/`, `openbao-snapshots/`, `teleport-recordings/`, `tempo-traces/`, `wazuh-archive/` — typically empty; verify and wipe contents if present
- [ ] You're doing this during low-load (the risk window between wipe and first fresh CNPG base backup is ~5–10 minutes during which the 4 CNPG clusters have no recent barman base backup)

## Procedure

### Step 1 — Drain user-irreplaceable data to host stage

For 2026-05-28's rotation this was just `member-hub-documents/` (2 objects, 3.6 KiB). If you have additional irreplaceable data, drain it too.

```bash
HOST_STAGE=/home/ops/mh-docs-rotation-stage-$(date +%Y%m%d-%H%M%S)
mkdir -p "$HOST_STAGE"

MINIO_POD=$(kubectl -n minio get pod -l app=minio -o jsonpath='{.items[0].metadata.name}')

# Enumerate object keys via mc ls --json (avoids find/awk — MinIO image is minimal)
mapfile -t KEYS < <(kubectl -n minio exec "$MINIO_POD" -- sh -c '
  mc alias set local http://localhost:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD >/dev/null 2>&1
  mc ls --recursive --json local/member-hub-documents/
' | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        if d.get("type") == "file":
            print(d.get("key", ""))
    except: pass
')

# Stream each object out via mc cat. MinIO decrypts on GET while the OLD key is still active.
for i in "${!KEYS[@]}"; do
  KEY="${KEYS[$i]}"
  HOST_FILE="$HOST_STAGE/object_${i}.bin"
  kubectl -n minio exec "$MINIO_POD" -- sh -c "
    mc alias set local http://localhost:9000 \$MINIO_ROOT_USER \$MINIO_ROOT_PASSWORD >/dev/null 2>&1
    mc cat local/member-hub-documents/$KEY
  " > "$HOST_FILE"
  echo "$KEY" > "$HOST_FILE.relpath"
  echo "[$i] $(sha256sum $HOST_FILE | awk '{print $1}')  $KEY"
done
```

**Verify sha256s are recorded and files are non-empty before proceeding to wipe.**

### Step 2 — Wipe SSE-encrypted prefixes

```bash
kubectl -n minio exec "$MINIO_POD" -- sh -c '
  mc alias set local http://localhost:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD >/dev/null 2>&1
  for prefix in \
    local/backups/cnpg/ \
    local/backups/velero/ \
    local/backups/sse-verify/ \
    local/member-hub-documents/ ; do
    echo "wiping $prefix"
    mc rm --recursive --force "$prefix" | tail -3
  done
  echo "--- after ---"
  mc du local/backups/ local/member-hub-documents/
'
```

After this the buckets should report `0B 0 objects`.

### Step 3 — Mint a break-glass admin token

The break-glass token is needed to write the new master key to OpenBao. See [openbao-recovery.md § Kubernetes auth break-glass](./openbao-recovery.md#kubernetes-auth-break-glass).

```bash
SA_JWT=$(kubectl -n openbao create token openbao --duration=10m)
ADMIN_TOKEN=$(kubectl -n openbao exec openbao-0 -c openbao -- \
    env BAO_ADDR=https://openbao.openbao.svc.cluster.local:8200 BAO_SKIP_VERIFY=1 \
    bao write -format=json auth/kubernetes/login \
        role=admin-break-glass jwt="$SA_JWT" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["auth"]["client_token"])')
```

### Step 4 — Generate the new master key

The naming convention is `secforge-minio-key-YYYY-MM-DD[-suffix]`. Using a new name (not just a new value under the same name) makes rotation history visible in audit + grep.

```bash
NEW_KEY_NAME="secforge-minio-key-$(date +%Y-%m-%d)"
NEW_KEY_B64=$(head -c 32 /dev/urandom | base64 -w0)
echo "new key name: $NEW_KEY_NAME (NOT echoing key bytes)"
```

### Step 5 — Write the new key to OpenBao

```bash
kubectl -n openbao exec openbao-0 -c openbao -- \
    env BAO_ADDR=https://openbao.openbao.svc.cluster.local:8200 BAO_SKIP_VERIFY=1 BAO_TOKEN="$ADMIN_TOKEN" \
    bao kv put secret/platform/minio/sse-master-key \
        key_name="$NEW_KEY_NAME" \
        master_key_b64="$NEW_KEY_B64"
```

This writes a new kv-v2 version (the previous version remains in OpenBao history for audit but is no longer the latest).

### Step 6 — Wait for VSO to render the new `minio-kms-creds` Secret

VSO polls every `refreshAfter` (default 60s). Wait + verify:

```bash
sleep 65
kubectl -n minio get secret minio-kms-creds -o jsonpath='{.data.MINIO_KMS_SECRET_KEY}' \
    | base64 -d | cut -d: -f1
# Expected output: the new key name (e.g. secforge-minio-key-2026-05-28)
```

### Step 7 — Restart MinIO + verify round-trip

```bash
kubectl -n minio rollout restart deploy/minio
kubectl -n minio rollout status deploy/minio --timeout=90s

# Round-trip test: write+read an object under the new key
NEW_MINIO_POD=$(kubectl -n minio get pod -l app=minio -o jsonpath='{.items[0].metadata.name}')
kubectl -n minio exec "$NEW_MINIO_POD" -- sh -c '
  mc alias set local http://localhost:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD >/dev/null 2>&1
  echo -n "rotation-verify-$(date +%s)" > /tmp/test.txt
  mc cp /tmp/test.txt local/backups/rotation-verify/test.txt
  mc cat local/backups/rotation-verify/test.txt
  mc rm local/backups/rotation-verify/test.txt
'
```

If the round-trip succeeds, MinIO is using the new key. If you see decryption errors, **stop and investigate** — do not proceed to re-upload.

### Step 8 — Re-upload staged data + sha256 verify

```bash
HOST_STAGE=<from step 1>
NEW_MINIO_POD=$(kubectl -n minio get pod -l app=minio -o jsonpath='{.items[0].metadata.name}')

for FILE in $HOST_STAGE/object_*.bin; do
  REL_PATH=$(cat "$FILE.relpath")
  ORIG_SHA=$(sha256sum "$FILE" | awk '{print $1}')

  # Stream file content via stdin into the pod, mc cp into MinIO from stdin
  kubectl -n minio exec -i "$NEW_MINIO_POD" -- sh -c "
    mc alias set local http://localhost:9000 \$MINIO_ROOT_USER \$MINIO_ROOT_PASSWORD >/dev/null 2>&1
    cat > /tmp/upload.bin
    mc cp /tmp/upload.bin local/member-hub-documents/$REL_PATH >/dev/null 2>&1
    rm -f /tmp/upload.bin
  " < "$FILE"

  # Verify by streaming back and sha256ing
  REMOTE_SHA=$(kubectl -n minio exec "$NEW_MINIO_POD" -- sh -c "
    mc alias set local http://localhost:9000 \$MINIO_ROOT_USER \$MINIO_ROOT_PASSWORD >/dev/null 2>&1
    mc cat local/member-hub-documents/$REL_PATH 2>/dev/null
  " | sha256sum | awk '{print $1}')

  if [ "$ORIG_SHA" = "$REMOTE_SHA" ]; then
    echo "  MATCH ($REMOTE_SHA)  $REL_PATH"
  else
    echo "  ✗ MISMATCH  orig=$ORIG_SHA  remote=$REMOTE_SHA  $REL_PATH"
  fi
done
```

**Every object must show MATCH before continuing.**

### Step 9 — Repopulate `backups/` under the new key

The CNPG clusters use the **barman-cloud plugin** model (not legacy `spec.backup.barmanObjectStore`). On-demand backups require `method: plugin`:

```bash
TS=$(date +%Y%m%d-%H%M%S)
for tuple in "control:control-db" "keycloak:secforge-keycloak-db" "member-hub:member-hub-db" "spicedb:secforge-spicedb-db"; do
  NS="${tuple%%:*}"
  CLUSTER="${tuple##*:}"
  cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: post-sse-rotation-$TS
  namespace: $NS
spec:
  cluster:
    name: $CLUSTER
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
done

# Wait + verify status=completed for each
sleep 30
kubectl get backup.postgresql.cnpg.io -A | grep "$TS"
```

Trigger an immediate Velero backup so the K8s resource state is also under the new key:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: post-sse-rotation-$TS
  namespace: velero
spec:
  ttl: 720h0m0s
EOF

kubectl -n velero get backup.velero.io post-sse-rotation-$TS -o jsonpath='{.status.phase}'
# Wait for "Completed". Velero takes longer than CNPG plugin-method (~5–10 min for full cluster).
```

### Step 10 — Clean up the host stage

```bash
rm -rf "$HOST_STAGE"
```

## What this rotation closes

- The OLD master key value (e.g. `yiHAu6cjhpfd1yuaHJPKvfxYzjQDoebt5DT9H3Wd40Y=` pre-2026-05-28) is now functionally dead — **no encrypted MinIO data on the box references it**.
- A copy of the OLD key value still exists in the kine MVCC history of `state.db` (k3s reuses freed pages but doesn't VACUUM); that copy is now a dead reference and yields nothing.
- New objects written after the rotation use the new key. Disk-theft of MinIO data + extraction of the new key from current state.db gives the attacker the same trust-root reach they'd have had with the old setup; **this rotation does not close the offline-disk attack surface, only the historical-bytes exposure**. LUKS on the host volumes is the proper closure for offline-disk.

## Recovery if something goes wrong mid-rotation

| Symptom | What it means | Fix |
|---|---|---|
| Round-trip test fails after MinIO restart (step 7) | The new key isn't valid, or VSO didn't render | `kubectl -n minio get secret minio-kms-creds -o yaml` and inspect `data.MINIO_KMS_SECRET_KEY` (base64-decode the `<name>:<base64>` payload). If empty/wrong: rewrite step 5 + bounce MinIO again. |
| sha256 mismatch on re-upload (step 8) | Network corruption or wrong relpath | Re-stream from host stage; verify `$REL_PATH` matches the original key path |
| CNPG Backup CR stays `Pending` for >2min (step 9) | The barman-cloud plugin pod isn't reachable | `kubectl -n cnpg-system get pod` — the plugin runs as a separate ns DaemonSet/Deployment |
| Velero Backup CR fails with "no BackupStorageLocation" | BSL drift | `kubectl -n velero get backupstoragelocation` — should show `default` Available |
| host stage was deleted before step 8 | Real user data lost | `member-hub-documents` records still exist in the member-hub DB; user uploads are gone. There is no recovery; user re-uploads. **This is why step 1 sha256s are critical.** |

## What this runbook does NOT cover

- Cluster greenfield rebuild (Tier 2 DR) — separate runbook (operator-backlog #64)
- Off-box backup destination — not configured today (deferred per operator decision until first paying customer)
- Multi-bucket per-tenant key separation — see ADR-0031 § "Per-bucket vs single key initially" for the future-fork design
