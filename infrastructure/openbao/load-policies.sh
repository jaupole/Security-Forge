#!/usr/bin/env bash
# Phase 5.5 — load OpenBao policies from infrastructure/openbao/policies/.
#
# Idempotent — `bao policy write` overwrites.

set -euo pipefail
NS=openbao
POD=openbao-0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set.\n" >&2; exit 1
fi

green() { printf '\033[32m%s\033[0m\n' "$*"; }

for f in "$HERE/policies"/*.hcl; do
    name=$(basename "$f" .hcl)
    green "==> bao policy write $name $f"
    kubectl exec -i -n "$NS" "$POD" -c openbao -- /bin/sh -c "cat > /tmp/$name.hcl" <"$f"
    kubectl exec -n "$NS" "$POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
        bao policy write "$name" "/tmp/$name.hcl" 2>&1 | tail -1
done

green ""
green "Loaded $(ls "$HERE/policies"/*.hcl | wc -l) policies."
green "List with: bao policy list"
