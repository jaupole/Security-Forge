#!/usr/bin/env bash
# 10a — Tailnet-only access for admin Ingresses.
#
# Patches every existing admin-shaped Ingress (Wazuh, Grafana, OpenBao
# admin, Keycloak admin, Prometheus, Alertmanager, etc.) with the
# `nginx.ingress.kubernetes.io/whitelist-source-range` annotation
# restricting source IPs to the Tailscale CGNAT range (100.64.0.0/10).
# After this runs, those admin UIs respond ONLY to traffic sourced from
# inside the tailnet — public-internet requests get a 403 at the ingress
# layer before the upstream pod is contacted.
#
# Also applies a Kyverno ClusterPolicy that REQUIRES the annotation on any
# Ingress with an admin-shaped hostname. Catches "I forgot the annotation"
# at admission time so accidental public exposure is impossible.
#
# Pre-conditions:
#   - 10-tailscale.sh ran AND your laptop has joined the same tailnet AND
#     you have verified you can reach the host via its tailnet IP.
#   - kubectl access to the cluster
#   - Kyverno is installed (it's in your existing stack — Phase 1 / 6b-2)
#
# Idempotent: re-running re-applies the annotation patches and reloads
# the Kyverno policy.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
M="$PLATFORM_DIR/manifests/tailscale"

# shellcheck disable=SC1091
set -a; source "$PLATFORM_DIR/globals.env"; set +a

# Hostnames that are admin-shaped — must match the Kyverno policy's
# preconditions in admin-allowlist-policy.yaml. Keep this list in sync
# with that file.
ADMIN_HOSTNAME_PREFIXES=(
    "wazuh."
    "grafana."
    "openbao-admin."
    "auth-admin."
    "prometheus."
    "alertmanager."
    "argocd."
    "kibana."
    "discover."
)

ALLOWLIST_VALUE="100.64.0.0/10"
ANNOTATION_KEY="nginx.ingress.kubernetes.io/whitelist-source-range"

# ── Sanity ────────────────────────────────────────────────────────────────

require_kubectl() {
    if ! command -v kubectl >/dev/null; then
        echo "ERROR: kubectl not on PATH" >&2
        exit 1
    fi
    if ! kubectl get nodes >/dev/null 2>&1; then
        echo "ERROR: kubectl can't reach cluster" >&2
        exit 1
    fi
}

require_kyverno() {
    if ! kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
        echo "ERROR: Kyverno CRDs not installed. Phase 1 / 6b-2 should have done this." >&2
        exit 1
    fi
}

# ── Patch existing admin Ingresses ────────────────────────────────────────

is_admin_hostname() {
    local host="$1"
    for prefix in "${ADMIN_HOSTNAME_PREFIXES[@]}"; do
        if [[ "$host" == "$prefix"* ]]; then
            return 0
        fi
    done
    return 1
}

patch_admin_ingresses() {
    echo ">>> Scanning all Ingresses across the cluster for admin-shaped hostnames"

    # All Ingresses, all namespaces, with their first rule's host.
    local ingresses_raw
    ingresses_raw=$(kubectl get ingress --all-namespaces \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.rules[0].host}{"\n"}{end}' \
        2>/dev/null)

    if [[ -z "$ingresses_raw" ]]; then
        echo "    no Ingresses found in cluster"
        return
    fi

    local patched=0
    local already_correct=0

    while IFS=$'\t' read -r ns name host; do
        [[ -z "$ns" || -z "$name" || -z "$host" ]] && continue
        if ! is_admin_hostname "$host"; then
            continue
        fi

        # Read the existing annotation, if any.
        local current
        current=$(kubectl -n "$ns" get ingress "$name" \
            -o jsonpath="{.metadata.annotations.$ANNOTATION_KEY}" 2>/dev/null || true)

        if [[ "$current" == *"$ALLOWLIST_VALUE"* ]]; then
            echo "    ✓ $ns/$name ($host) — annotation already set"
            already_correct=$(( already_correct + 1 ))
            continue
        fi

        # Build the merged value: if current is non-empty and doesn't
        # already include CGNAT, prepend CGNAT to it (preserve any other
        # CIDRs the operator added). If empty, just set CGNAT.
        local merged
        if [[ -z "$current" ]]; then
            merged="$ALLOWLIST_VALUE"
        else
            merged="$ALLOWLIST_VALUE,$current"
        fi

        echo "    → patching $ns/$name ($host) with $ANNOTATION_KEY = $merged"
        # JSON-patch via merge — simpler than escaping everything for kubectl annotate.
        kubectl -n "$ns" patch ingress "$name" --type=merge \
            -p "{\"metadata\":{\"annotations\":{\"$ANNOTATION_KEY\":\"$merged\"}}}" \
            >/dev/null
        patched=$(( patched + 1 ))
    done <<< "$ingresses_raw"

    echo ""
    echo "    Summary: $patched patched, $already_correct already correct"
}

# ── Apply the Kyverno enforcement policy ──────────────────────────────────

apply_kyverno_policy() {
    local policy_file="$M/admin-allowlist-policy.yaml"
    [[ -f "$policy_file" ]] || { echo "ERROR: policy file missing: $policy_file" >&2; exit 1; }

    echo ">>> Applying Kyverno ClusterPolicy: admin-ingress-must-be-tailnet-only"
    kubectl apply -f "$policy_file"

    # Wait for the policy to be Ready (Kyverno reports policy-load status).
    echo ">>> Waiting for policy to be Ready"
    local elapsed=0
    while (( elapsed < 30 )); do
        local ready
        ready=$(kubectl get clusterpolicy admin-ingress-must-be-tailnet-only \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        if [[ "$ready" == "True" ]]; then
            echo "    Ready."
            return 0
        fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
    done
    echo "WARNING: policy did not reach Ready=True within 30s." >&2
    echo "  Inspect: kubectl describe clusterpolicy admin-ingress-must-be-tailnet-only" >&2
}

# ── Verification ──────────────────────────────────────────────────────────

verify_policy_in_force() {
    echo ""
    echo ">>> Verifying policy is in Enforce mode (will REJECT non-compliant Ingress creates):"
    local mode
    mode=$(kubectl get clusterpolicy admin-ingress-must-be-tailnet-only \
        -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null || true)
    echo "    validationFailureAction = $mode"
    if [[ "$mode" != "Enforce" ]]; then
        echo "    WARNING: policy is in Audit mode — non-compliant Ingresses will be allowed but flagged. Switch to Enforce when comfortable." >&2
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────

main() {
    require_kubectl
    require_kyverno
    patch_admin_ingresses
    apply_kyverno_policy
    verify_policy_in_force

    cat <<EOF

✓ Component 10a — admin Ingresses restricted to Tailscale CGNAT.

  Allowlist:    $ALLOWLIST_VALUE  (Tailscale CGNAT range)
  Annotation:   $ANNOTATION_KEY
  Policy:       ClusterPolicy/admin-ingress-must-be-tailnet-only (Enforce)

What changed:
  - Existing admin Ingresses (wazuh.*, grafana.*, openbao-admin.*,
    auth-admin.*, prometheus.*, alertmanager.*, etc.) now respond ONLY
    to traffic sourced from inside the tailnet. From the public internet
    they return 403 at the ingress layer before reaching the upstream pod.
  - Kyverno will REJECT any new admin-shaped Ingress that doesn't have
    the allowlist annotation. Catches "I forgot to add it" at admission.

Verify from your laptop (you should be on the tailnet):
  curl -I https://wazuh.${DOMAIN}            # → 200 OK or 302 (login redirect)

Verify from off-tailnet (e.g. mobile data, no Tailscale running):
  curl -I https://wazuh.${DOMAIN}            # → 403 Forbidden

To make a SPECIFIC PAGE of an otherwise-internal service public:
  Create a separate Ingress with a non-admin-shaped hostname (e.g.
  status.${DOMAIN} for a public health endpoint that lives in the same
  cluster as the admin Wazuh dashboard). The Kyverno policy doesn't
  match it, so no annotation is required, and it serves to the world.

Next:
  bash $SCRIPT_DIR/10b-sshd-lockdown.sh   # bind sshd to tailnet only

EOF
}

main "$@"
