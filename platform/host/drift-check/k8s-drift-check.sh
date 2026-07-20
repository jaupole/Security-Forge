#!/usr/bin/env bash
# k8s-drift-check.sh — detect merge-without-apply drift between the repo
# (/home/ops/secforge, the deploy source of truth) and the live cluster.
#
# WHY: there is no GitOps controller — the deploy policy is edit-repo →
# kubectl apply → PR, so a merged commit that nobody applies drifts silently.
# The 2026-07-05 infra sweep found five separate findings in this class
# (app-alerts PrometheusRule unapplied for 46 days, VSO/trust-manager digest
# pins merged-not-helm-upgraded, guardrail-selftest image stale, spicedb-
# operator pin unapplied, live-only ClusterPolicy). This check makes the
# class self-surfacing.
#
# WHAT it does (read-only against the cluster):
#   1. For every manifest under platform/manifests/** (minus exclusions),
#      render with the SAME envsubst allowlist as apply-manifest.sh and run
#      a server-side dry-run `kubectl diff`.
#   2. For every pinned helm release in HELM_RELEASES, compare
#      `helm get values` (user-supplied values) against the rendered repo
#      values file — catches merged-but-never-`helm upgrade`d values.
#   3. For every release in HELM_RELEASES, diff the DEPLOYED release
#      manifest (helm get manifest) against the live objects — catches the
#      drift class helm cannot self-repair: a FAILED upgrade that partially
#      mutated live objects before dying leaves residue no later manifest-
#      to-manifest diff will ever touch (kps rev-8 left a literal
#      \ in the Prometheus/Alertmanager CRs for 8 days,
#      RCA 2026-07-18), plus manual kubectl edits to helm-owned objects.
#   4. Write node-exporter textfile metrics; PrometheusRule
#      SecforgeManifestDrift / SecforgeHelmValuesDrift /
#      SecforgeHelmManifestDrift alert on them.
#      Per-file detail lands in the journal (journalctl -u k8s-drift-check).
#
# Runs as root from a systemd timer (see k8s-drift-check.timer, daily).
# Exit code is always 0 unless the check itself is broken — drift is
# reported via metrics, not exit status, so the timer never flaps.

set -uo pipefail

REPO=/home/ops/secforge
PLATFORM_DIR="$REPO/platform"
OUTDIR=/var/lib/node_exporter/textfile_collector
OUTFILE="$OUTDIR/secforge_drift.prom"
TMPFILE="$OUTFILE.tmp"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Same allowlist as platform/lib/apply-manifest.sh — keep in sync.
ALLOW='${DOMAIN} ${SPIFFE_TRUST_DOMAIN} ${SPIRE_CLUSTER_NAME} ${LE_ISSUER} ${LE_EMAIL} ${WILDCARD_CERT_NAMESPACE} ${WILDCARD_CERT_SECRET} ${STORAGE_CLASS} ${KEYCLOAK_PLATFORM_REALM} ${KEYCLOAK_TENANTS_REALM} ${TIMEZONE} ${PUBLIC_IP} ${TAILNET_IP}'

# Paths (regex, matched against the repo-relative path) that must NOT be
# diffed. Keep each entry justified:
#   - vendor-chart/            wazuh is helm-managed, not kubectl-applied
#   - _egress-baseline/        .tpl applied per-namespace with ${NS}
#   - image-build/             retired kaniko recipes, not cluster objects
#   - credentials-job|migration-job|image-build-job
#                              immutable one-shot Jobs: diff always errors
#   - realm-import|-realm\.yaml keycloak realm imports are one-shot CRs; the
#                              authoritative realm state lives in Keycloak's DB
#   - spicedb/tests/         SpiceDB validation fixtures, not k8s objects
#   - /realms/               keycloak realm-import payloads (one-shot; realm
#                            truth lives in Keycloak's DB)
#   - bootstrap-job          immutable one-shot Jobs (minio bucket bootstrap)
#   - keycloak/operator/     vendor bundle (kustomization is not a k8s object;
#                            operator.yaml PSA-warns on server dry-run)
EXCLUDE='vendor-chart/|_egress-baseline/|/image-build/|credentials-job|migration-job|bootstrap-job|realm-import|/realms/|spicedb/tests/|keycloak/operator/|13-kyverno-image-verify-note'

# Helm releases whose values files are the source of truth:
#   release:namespace:values-file
# NOTE: an earlier revision claimed kyverno was "NOT a helm release" — wrong.
# The release has existed since 2026-05-08; the helm ls that wrote that note ran
# without KUBECONFIG and saw an empty list. Reconciled 2026-07-19 (rev 2 helm
# upgrade baked the live-patched --exceptionNamespace args into the stored
# manifest); kyverno is drift-checked like every other release below.
HELM_RELEASES=(
  "vault-secrets-operator:vault-secrets-operator:values/vault-secrets-operator.yaml"
  "trust-manager:cert-manager:values/trust-manager.yaml"
  "kps:observability:values/kube-prometheus-stack.yaml"
  "loki:observability:values/loki.yaml"
  "trivy-operator:trivy-system:values/trivy-operator.yaml"
  "velero:velero:values/velero.yaml"
  "minio:minio:values/minio.yaml"
  # wazuh added 2026-07-19 — it was absent from both drift checks while its
  # values file drifted (indexer memory bump applied only via helm upgrade).
  "wazuh:wazuh:values/wazuh.yaml"
  "kyverno:kyverno:values/kyverno.yaml"
)

set -a
# shellcheck disable=SC1091
source "$PLATFORM_DIR/globals.env"
set +a

drifted=0 errored=0 checked=0
while IFS= read -r f; do
  rel="${f#"$REPO/"}"
  [[ "$rel" =~ $EXCLUDE ]] && continue
  checked=$((checked + 1))
  out=$(envsubst "$ALLOW" < "$f" | kubectl diff -f - 2>&1)
  rc=$?
  if [ $rc -eq 1 ]; then
    # Ignore generation-only diffs: Kyverno mutate policies make the server
    # dry-run predict a generation bump on some objects with zero real field
    # changes (observed on system-netpol/kube-system-allows) — permanent
    # phantom otherwise.
    real=$(echo "$out" | grep -E '^[+-]' | grep -vE '^[+-]{3}' | grep -cv 'generation:')
    if [ "$real" -eq 0 ]; then rc=0; fi
  fi
  if [ $rc -eq 1 ]; then
    drifted=$((drifted + 1))
    echo "DRIFT: $rel"
    echo "$out" | grep -E '^[+-]' | grep -vE '^[+-]{3}' | head -20
  elif [ $rc -gt 1 ]; then
    errored=$((errored + 1))
    echo "ERROR: $rel: $(echo "$out" | head -2 | tr '\n' ' ')"
  fi
done < <(find "$PLATFORM_DIR/manifests" -name '*.yaml' -type f | sort)

helm_drifted=0
for entry in "${HELM_RELEASES[@]}"; do
  IFS=: read -r release ns values <<< "$entry"
  live=$(helm get values "$release" -n "$ns" -o json 2>/dev/null)
  # default=str: YAML date-typed scalars (loki schemaConfig from:) must
  # stringify the same way helm's JSON output renders them.
  want=$(envsubst "$ALLOW" < "$PLATFORM_DIR/$values" | python3 -c 'import json,sys,yaml; print(json.dumps(yaml.safe_load(sys.stdin), sort_keys=True, default=str))' 2>/dev/null)
  norm_live=$(echo "$live" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))' 2>/dev/null)
  if [ -z "$live" ]; then
    echo "ERROR: helm release $ns/$release not found"
    errored=$((errored + 1))
  elif [ "$norm_live" != "$want" ]; then
    helm_drifted=$((helm_drifted + 1))
    echo "HELM DRIFT: $ns/$release values != $values (merged but never helm-upgraded?)"
  fi
done

# Live-vs-deployed-manifest drift (see header item 3). Repair = kubectl patch
# the live object back to the rendered-manifest value; a plain re-run of the
# owning component script will NOT fix it (no manifest-to-manifest diff).
helm_manifest_drifted=0
for entry in "${HELM_RELEASES[@]}"; do
  IFS=: read -r release ns values <<< "$entry"
  manifest=$(helm get manifest "$release" -n "$ns" 2>/dev/null)
  if [ -z "$manifest" ]; then
    echo "ERROR: helm get manifest $ns/$release returned nothing"
    errored=$((errored + 1))
    continue
  fi
  # Doc filter before diffing:
  #   - ClusterComplianceReport dropped: the trivy-operator chart embeds the
  #     builtin compliance reports from static assets (managed-by: kubectl
  #     label baked in) while the operator reconciles the live CRs at runtime
  #     — their truth is the operator's; permanent label-only phantom.
  #   - PersistentVolumeClaim dropped: chart-templated PVCs collide with the
  #     static-PV binding pattern (minio/wazuh bind pre-created PVs; PVC truth
  #     lives in manifests/*/static-pvs*, covered by the manifest loop above)
  #     and admission-defaulted immutable spec fields error the dry-run.
  #   - Release namespace injected into namespace-less namespaced docs (helm
  #     injects it at install; kubectl diff -n errors on multi-ns charts like
  #     kps that also ship explicit kube-system objects).
  manifest=$(printf '%s' "$manifest" | NS="$ns" python3 -c 'import os, sys, yaml
CLUSTER_SCOPED = {"Namespace", "ClusterRole", "ClusterRoleBinding",
    "CustomResourceDefinition", "MutatingWebhookConfiguration",
    "ValidatingWebhookConfiguration", "ValidatingAdmissionPolicy",
    "ValidatingAdmissionPolicyBinding", "PriorityClass", "IngressClass",
    "StorageClass", "PersistentVolume", "APIService", "RuntimeClass",
    "ClusterPolicy", "ClusterComplianceReport"}
DROP = {"ClusterComplianceReport", "PersistentVolumeClaim"}
docs = []
for d in yaml.safe_load_all(sys.stdin):
    if not d or d.get("kind") in DROP:
        continue
    if d["kind"] not in CLUSTER_SCOPED and not d["metadata"].get("namespace"):
        d["metadata"]["namespace"] = os.environ["NS"]
    docs.append(d)
print(yaml.safe_dump_all(docs, default_flow_style=False))')
  out=$(printf '%s' "$manifest" | kubectl diff -f - 2>&1)
  rc=$?
  if [ $rc -eq 1 ]; then
    # Generation phantom filter (as the manifest loop above) plus live-only
    # operational annotations a re-apply would strip: rollout revision,
    # rollout-restart timestamps, helm adoption markers.
    real=$(echo "$out" | grep -E '^[+-]' | grep -vE '^[+-]{3}' | grep -cvE 'generation:|deployment\.kubernetes\.io/revision|kubectl\.kubernetes\.io/restartedAt|meta\.helm\.sh/release-')
    if [ "$real" -eq 0 ]; then rc=0; fi
  fi
  if [ $rc -eq 1 ]; then
    helm_manifest_drifted=$((helm_manifest_drifted + 1))
    echo "HELM MANIFEST DRIFT: $ns/$release live objects != deployed release manifest"
    echo "$out" | grep -E '^[+-]' | grep -vE '^[+-]{3}' | head -20
  elif [ $rc -gt 1 ]; then
    errored=$((errored + 1))
    echo "ERROR: helm manifest diff $ns/$release: $(echo "$out" | head -2 | tr '
' ' ')"
  fi
done

mkdir -p "$OUTDIR"
cat > "$TMPFILE" <<EOF
# HELP secforge_manifest_drift_files Manifests whose rendered content differs from the live cluster (merge-without-apply drift).
# TYPE secforge_manifest_drift_files gauge
secforge_manifest_drift_files $drifted
# HELP secforge_helm_values_drift_releases Helm releases whose live user-supplied values differ from the repo values file.
# TYPE secforge_helm_values_drift_releases gauge
secforge_helm_values_drift_releases $helm_drifted
# HELP secforge_helm_manifest_drift_releases Helm releases whose live objects differ from the deployed release manifest (failed-upgrade residue or manual edit; helm cannot self-repair this).
# TYPE secforge_helm_manifest_drift_releases gauge
secforge_helm_manifest_drift_releases $helm_manifest_drifted
# HELP secforge_drift_check_errors Files/releases the drift check could not evaluate.
# TYPE secforge_drift_check_errors gauge
secforge_drift_check_errors $errored
# HELP secforge_drift_check_files_total Manifests evaluated in the last run.
# TYPE secforge_drift_check_files_total gauge
secforge_drift_check_files_total $checked
# HELP secforge_drift_check_last_run_timestamp_seconds Unix time of the last completed drift check.
# TYPE secforge_drift_check_last_run_timestamp_seconds gauge
secforge_drift_check_last_run_timestamp_seconds $(date +%s)
EOF
# node-exporter runs as nobody: the file must be world-readable no matter the
# caller's umask (root's hardened 0027 broke scrapes for 13h on 2026-07-19
# after a manual sudo run; systemd's 022 masked it on scheduled runs).
chmod 0644 "$TMPFILE"
mv "$TMPFILE" "$OUTFILE"

echo "done: checked=$checked drifted=$drifted helm_drifted=$helm_drifted helm_manifest_drifted=$helm_manifest_drifted errors=$errored"
