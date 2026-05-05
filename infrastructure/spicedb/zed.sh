#!/usr/bin/env bash
# Run the `zed` CLI against the in-cluster SpiceDB. Drop-in for `zed`.
#
# Examples:
#   bash zed.sh schema read
#   bash zed.sh relationship create document:welcome#owner user:jason
#   bash zed.sh permission check document:welcome view user:jason

set -euo pipefail
NS=spicedb

PSK=$(kubectl get secret -n "$NS" spicedb-config-vso -o jsonpath='{.data.preshared_key}' | base64 -d)

# Use a cached pod that we keep around for repeated invocations would
# be nicer, but exec'ing each time is more idempotent for IaC use.
exec kubectl run -n "$NS" --rm -i --quiet --restart=Never \
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
          "stdin": true,
          "args": ['"$(printf '"%s",' "$@" | sed 's/,$//')"',
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
    "zed-cli-$(date +%s%N | cut -c10-19)" -- /dev/null
