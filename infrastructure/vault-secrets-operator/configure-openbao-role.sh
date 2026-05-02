#!/usr/bin/env bash
# Phase 6.10b Step 2 — create OpenBao K8s auth role + write `vso` policy.
#
# Pre-conditions:
#   - main OpenBao initialized + unsealed
#   - K8s auth method enabled (Phase 5.4 — configure-auth-k8s-jwt.sh)
#   - vault-secrets-operator namespace exists (apply namespaces.yaml first)
#   - VSO Helm release installed (so the SA exists)
#   - BAO_TOKEN env var set to an OIDC-issued admin token. The Phase 5
#     initial-root-token is GONE (revoked at end of Phase 5; see PLAN.md
#     ~line 159). Authenticate with the OIDC admin role configured in
#     Phase 5.6 (Keycloak `openbao` client → admin role binding):
#
#         bao login -method=oidc role=admin
#         export BAO_TOKEN=$(bao print token)
#         bash configure-openbao-role.sh
#
#     Requires the `bao` CLI on the WSL host (see auto-memory
#     `host_bao_cli_missing.md` — installed in Phase 6.10b Step 2).
#     Script *operations* run via `kubectl exec` into openbao-0; only
#     the login step needs the host CLI.
#
# Idempotent: `bao policy write` overwrites; `bao write auth/.../role/X`
# overwrites.

set -euo pipefail

NS=openbao
POD=openbao-0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICIES_DIR="$HERE/../openbao/policies"

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set. Pass an admin token:\n" >&2
    printf "  BAO_TOKEN=s.XXX bash configure-openbao-role.sh\n" >&2
    exit 1
fi

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

bao() {
    kubectl exec -n "$NS" "$POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" "$@"
}

# Sanity: VSO ServiceAccount must exist before binding.
if ! kubectl -n vault-secrets-operator get sa vault-secrets-operator-controller-manager >/dev/null 2>&1; then
    red "ServiceAccount vault-secrets-operator-controller-manager not found"
    red "in namespace vault-secrets-operator. Did Helm install run?"
    exit 1
fi

# 1. Write the `vso` policy.
green "==> writing policy: vso"
POLICY_FILE="$POLICIES_DIR/vso.hcl"
if [ ! -f "$POLICY_FILE" ]; then
    red "policy file not found: $POLICY_FILE"
    exit 1
fi
kubectl exec -i -n "$NS" "$POD" -c openbao -- \
    /bin/sh -c "cat > /tmp/vso.hcl" <"$POLICY_FILE"
bao bao policy write vso /tmp/vso.hcl 2>&1 | tail -1

# 2. Create the K8s auth roles binding consumer SAs → policy.
#
# Note on `audience`: this MUST match the audience VSO presents in its
# projected SA token (configured in 03-vault-auth.yaml and the per-
# consumer VaultAuth manifests in
# infrastructure/spicedb/06-vso-binding.yaml and
# apps/authzen-facade/deploy/05-vso-binding.yaml). We use the K8s API
# server issuer URL `https://kubernetes.default.svc.cluster.local`
# rather than the historical "vault" shorthand — both sides must agree.
# Self-documenting: a future reader debugging an auth failure can grep
# for the URL in any of these four files.
#
# THREE roles get written:
#   - `vault-secrets-operator` — operator-self auth (Step 2).
#   - `spicedb-vso` — consumer-side auth for the spicedb namespace.
#   - `authzen-facade-vso` — consumer-side auth for the app namespace.
# All three share the same `vso` policy. The split-by-role design keeps
# audit logs attributable to the consumer (who read what) and makes
# revocation per-consumer trivial.

K8S_AUDIENCE="https://kubernetes.default.svc.cluster.local"

green "==> writing K8s auth role: vault-secrets-operator (operator-self)"
bao bao write auth/kubernetes/role/vault-secrets-operator \
    bound_service_account_names="vault-secrets-operator-controller-manager" \
    bound_service_account_namespaces="vault-secrets-operator" \
    audience="$K8S_AUDIENCE" \
    policies="vso" \
    ttl="1h" \
    max_ttl="24h" 2>&1 | tail -1

green "==> writing K8s auth role: spicedb-vso (spicedb ns consumer)"
bao bao write auth/kubernetes/role/spicedb-vso \
    bound_service_account_names="spicedb-vso" \
    bound_service_account_namespaces="spicedb" \
    audience="$K8S_AUDIENCE" \
    policies="vso" \
    ttl="1h" \
    max_ttl="24h" 2>&1 | tail -1

green "==> writing K8s auth role: authzen-facade-vso (app ns consumer)"
bao bao write auth/kubernetes/role/authzen-facade-vso \
    bound_service_account_names="authzen-facade-vso" \
    bound_service_account_namespaces="app" \
    audience="$K8S_AUDIENCE" \
    policies="vso" \
    ttl="1h" \
    max_ttl="24h" 2>&1 | tail -1

# Phase 7.3 — Grafana OIDC client_secret rendered to a K8s Secret in
# observability namespace; consumed by the kube-prometheus-stack chart's
# grafana subchart via envFromSecret.
green "==> writing K8s auth role: grafana-vso (observability ns consumer)"
bao bao write auth/kubernetes/role/grafana-vso \
    bound_service_account_names="grafana-vso" \
    bound_service_account_namespaces="observability" \
    audience="$K8S_AUDIENCE" \
    policies="vso" \
    ttl="1h" \
    max_ttl="24h" 2>&1 | tail -1

# Phase 7.4 — Loki MinIO scoped-user credentials.
green "==> writing K8s auth role: loki-vso (observability ns consumer)"
bao bao write auth/kubernetes/role/loki-vso \
    bound_service_account_names="loki-vso" \
    bound_service_account_namespaces="observability" \
    audience="$K8S_AUDIENCE" \
    policies="vso" \
    ttl="1h" \
    max_ttl="24h" 2>&1 | tail -1

# Phase 7.5 — Tempo MinIO scoped-user credentials.
green "==> writing K8s auth role: tempo-vso (observability ns consumer)"
bao bao write auth/kubernetes/role/tempo-vso \
    bound_service_account_names="tempo-vso" \
    bound_service_account_namespaces="observability" \
    audience="$K8S_AUDIENCE" \
    policies="vso" \
    ttl="1h" \
    max_ttl="24h" 2>&1 | tail -1

# Phase 7d Item 7 — Wazuh dashboard OIDC client_secret rendered to a
# K8s Secret in wazuh ns; consumed by the dashboard pod's
# opensearch_dashboards.yml config (operator runs configure-wazuh-oidc.sh
# to wire it into the running config).
green "==> writing K8s auth role: wazuh-vso (wazuh ns consumer)"
bao bao write auth/kubernetes/role/wazuh-vso \
    bound_service_account_names="wazuh-vso" \
    bound_service_account_namespaces="wazuh" \
    audience="$K8S_AUDIENCE" \
    policies="vso" \
    ttl="1h" \
    max_ttl="24h" 2>&1 | tail -1

# Phase 8a — Teleport namespace consumes Keycloak OIDC client_secret +
# scoped MinIO creds for session-recording S3 backend. Both rendered as
# K8s Secrets in teleport ns by VSO; auth pod (Phase 8b) references via
# secretKeyRef in chart values.
green "==> writing K8s auth role: teleport-vso (teleport ns consumer)"
bao bao write auth/kubernetes/role/teleport-vso \
    bound_service_account_names="teleport-vso" \
    bound_service_account_namespaces="teleport" \
    audience="$K8S_AUDIENCE" \
    policies="vso" \
    ttl="1h" \
    max_ttl="24h" 2>&1 | tail -1

green ""
green "Done. Six K8s auth roles bound to the 'vso' policy:"
green "  - vault-secrets-operator (operator-self, Step 2)"
green "  - spicedb-vso             (spicedb ns consumer, Step 3)"
green "  - authzen-facade-vso      (app ns consumer, Step 3)"
green "  - grafana-vso             (observability ns consumer, Phase 7.3)"
green "  - loki-vso                (observability ns consumer, Phase 7.4)"
green "  - tempo-vso               (observability ns consumer, Phase 7.5)"
green ""
green "Verify with:"
green "  kubectl -n vault-secrets-operator logs deploy/vault-secrets-operator-controller-manager | grep -i 'auth.*succeeded'"
green ""
