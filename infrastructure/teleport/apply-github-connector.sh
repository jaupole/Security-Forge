#!/usr/bin/env bash
# Phase 8b prototype B — wire the Teleport GithubConnector.
#
# Pre-conditions (already true after the foundation work in this commit):
#   - infrastructure/openbao/policies/vso.hcl extended with the
#     secret/data/teleport/github path → load-policies.sh re-run.
#   - infrastructure/teleport/01-vso-binding.yaml applied (creates the
#     teleport-github VaultStaticSecret + teleport-github-vso K8s Secret).
#   - teleport-cluster Helm release running (auth + proxy + operator).
#   - Operator already started its TeleportGithubConnector controller.
#
# Inputs (all required):
#   $1 GITHUB_CLIENT_ID     — GitHub OAuth App "Client ID" field
#   $2 GITHUB_CLIENT_SECRET — GitHub OAuth App "Client secret" (one-time displayed)
#   $3 GITHUB_ORG           — GitHub org slug containing the team
#   $4 GITHUB_TEAM          — Team slug within that org
#
# Env:
#   BAO_TOKEN — OpenBao admin token (see bao login -method=oidc role=admin).
#
# What this script does:
#   1. Writes client_id + client_secret + org + team to OpenBao at
#      secret/data/teleport/github (idempotent — overwrites if present).
#   2. Waits for VSO to render teleport-github-vso in the teleport ns.
#   3. Substitutes __GITHUB_CLIENT_ID__ / __GITHUB_ORG__ / __GITHUB_TEAM__
#      into 06-github-connector.yaml and kubectl applies it.
#   4. Waits for the operator to upsert the connector into Teleport.
#
# After this completes, sign-in URL:
#   https://tp.secforge.local/web → "Sign in with GitHub" button.

set -euo pipefail

if [ "$#" -ne 4 ]; then
    cat >&2 <<EOF
usage: $0 <client_id> <client_secret> <github_org> <github_team>

Get the client_id + client_secret from GitHub:
  Settings → Developer settings → OAuth Apps → SecForge Local Teleport.
  (Client secret is shown ONCE; if you missed it, "Generate a new client secret".)

Get the org + team slugs from the team's URL:
  https://github.com/orgs/<ORG>/teams/<TEAM>
EOF
    exit 1
fi

GITHUB_CLIENT_ID="$1"
GITHUB_CLIENT_SECRET="$2"
GITHUB_ORG="$3"
GITHUB_TEAM="$4"

NS=teleport
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENBAO_PATH=secret/teleport/github

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

[ -z "${BAO_TOKEN:-}" ] && { red "BAO_TOKEN env var required"; exit 1; }

# ─── 1. Write to OpenBao ───────────────────────────────────────────────
green "==> writing GitHub OAuth credentials to OpenBao at $OPENBAO_PATH"
kubectl exec -n openbao openbao-0 -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao kv put "$OPENBAO_PATH" \
        client_id="$GITHUB_CLIENT_ID" \
        client_secret="$GITHUB_CLIENT_SECRET" \
        github_org="$GITHUB_ORG" \
        github_team="$GITHUB_TEAM" \
    >/dev/null

# ─── 2. Wait for VSO to render teleport-github-vso ─────────────────────
green "==> waiting for VSO to render teleport-github-vso (up to 90s)"
for i in $(seq 1 18); do
    if kubectl -n "$NS" get secret teleport-github-vso >/dev/null 2>&1; then
        # Verify the client_secret key is populated.
        VAL=$(kubectl -n "$NS" get secret teleport-github-vso \
            -o jsonpath='{.data.client_secret}' | base64 -d)
        if [ -n "$VAL" ]; then
            green "    rendered after $((i*5))s"
            break
        fi
    fi
    if [ "$i" -eq 18 ]; then
        red "VSO did not render teleport-github-vso within 90s"
        kubectl -n "$NS" describe vaultstaticsecret teleport-github | tail -20
        exit 1
    fi
    sleep 5
done

# ─── 3. Render + apply the connector CR ────────────────────────────────
green "==> rendering 06-github-connector.yaml (substitute org/team/client_id)"
TMP=$(mktemp)
trap "rm -f $TMP" EXIT
sed -e "s|__GITHUB_CLIENT_ID__|$GITHUB_CLIENT_ID|g" \
    -e "s|__GITHUB_ORG__|$GITHUB_ORG|g" \
    -e "s|__GITHUB_TEAM__|$GITHUB_TEAM|g" \
    "$HERE/06-github-connector.yaml" > "$TMP"

green "==> applying TeleportGithubConnector CR"
kubectl apply -f "$TMP"

# ─── 4. Wait for operator to upsert into Teleport ──────────────────────
green "==> waiting for operator to reconcile (up to 60s)"
for i in $(seq 1 12); do
    if kubectl logs -n "$NS" -l app.kubernetes.io/name=teleport-cluster-operator \
            --tail=200 --since=2m 2>/dev/null \
            | grep -q "teleportgithubconnector.*github.*upsert object in Teleport"; then
        green "    operator reported upsert success after $((i*5))s"
        break
    fi
    if [ "$i" -eq 12 ]; then
        yellow "operator did not log success within 60s — check manually:"
        echo "  kubectl logs -n $NS -l app.kubernetes.io/name=teleport-cluster-operator --tail=50 | grep github"
        exit 1
    fi
    sleep 5
done

green "==> done"
echo
echo "Test sign-in:"
echo "  Browser → https://tp.secforge.local/web → 'Sign in with GitHub'"
echo
echo "CLI sign-in (after installing tsh on your workstation):"
echo "  tsh login --proxy=tp.secforge.local --auth=github"
