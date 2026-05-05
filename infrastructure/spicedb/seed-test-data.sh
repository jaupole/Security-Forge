#!/usr/bin/env bash
# Apply infrastructure/spicedb/seed-test-data.yaml (schema + relationships)
# to the running SpiceDB. Idempotent on schema; relationships use TOUCH
# semantics so re-runs don't error on duplicates.

set -euo pipefail
NS=spicedb
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PSK=$(kubectl get secret -n "$NS" spicedb-config-vso -o jsonpath='{.data.preshared_key}' | base64 -d)

# Copy the seed YAML into a one-shot pod and run `zed import`.
# `--schema-definition-prefix` left blank so definition names match the
# baseline schema (no prefix expected).
kubectl run -n "$NS" --rm -i --quiet --restart=Never \
    --image=authzed/zed:v1.0.0 \
    --labels=role=zed-cli-oneshot \
    --overrides='
    {
      "spec": {
        "securityContext": {
          "runAsNonRoot": true,
          "runAsUser": 65532,
          "seccompProfile": {"type": "RuntimeDefault"}
        },
        "containers": [{
          "name": "zed",
          "image": "authzed/zed:v1.0.0",
          "stdin": true, "stdinOnce": true, "tty": false,
          "args": ["import", "/dev/stdin",
                   "--endpoint", "spicedb.spicedb.svc.cluster.local:50051",
                   "--token",    "'"$PSK"'",
                   "--no-verify-ca"],
          "securityContext": {
            "allowPrivilegeEscalation": false,
            "readOnlyRootFilesystem": true,
            "runAsNonRoot": true,
            "capabilities": {"drop": ["ALL"]},
            "seccompProfile": {"type": "RuntimeDefault"}
          }
        }]
      }
    }' \
    zed-import-seed <"$HERE/seed-test-data.yaml"

echo
echo "Seed data applied. Verify with:"
echo "  bash infrastructure/spicedb/check-permissions.sh"
