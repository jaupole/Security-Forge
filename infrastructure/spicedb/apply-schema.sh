#!/usr/bin/env bash
# Apply infrastructure/spicedb/schema.zed to the running SpiceDB.
#
# Idempotent: re-running with the same schema is a no-op (zed
# diff-checks before write). Re-running with a *different* schema
# performs a schema migration in SpiceDB — relationships referencing
# removed types or relations will fail validation; SpiceDB will
# reject the write. Run validator tests first.

set -euo pipefail
NS=spicedb
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# Pull the PSK out of the spicedb-config Secret (created by apply.sh).
PSK=$(kubectl get secret -n "$NS" spicedb-config -o jsonpath='{.data.preshared_key}' | base64 -d)

# Run zed write-schema as a one-shot pod inside the cluster. We use
# the same authzed/zed image as the validator tests; zed talks to
# SpiceDB over its in-cluster Service (with TLS skip-verify because
# the mkcert CA isn't in zed's trust store, AND the cert's name
# matches the in-cluster service which isn't externally-resolvable).
green "==> Applying schema from infrastructure/spicedb/schema.zed"
kubectl run -n "$NS" --rm -i --restart=Never --quiet \
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
          "args": ["schema", "write",
                   "--endpoint", "spicedb.spicedb.svc.cluster.local:50051",
                   "--token",    "'"$PSK"'",
                   "--no-verify-ca",
                   "/dev/stdin"],
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
    zed-write-schema <"$HERE/schema.zed"

green ""
green "Schema applied. Verify:"
green "  bash infrastructure/spicedb/zed.sh schema read"
