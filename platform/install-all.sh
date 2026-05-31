#!/usr/bin/env bash
# install-all.sh — orchestrates a fresh-deploy run of the SecForge
# platform components on a freshly-provisioned bare-metal host.
#
# Components are organized in numbered groups by phase:
#
#   Group 00 — host + foundational cluster substrate
#     00-host-bootstrap        sysctl + ufw + unattended-upgrades + k3s audit policy
#     00b-cert-manager         cert-manager + LE issuers + CF token via VSO + wildcard cert
#     00c-ingress-nginx        nginx ingress controller (hostPort mode)
#     00d-wazuh-storage        wazuh-local SC + static PVs on /var/lib/wazuh partition
#     00e-minio-storage        minio-local SC + static PV on /var/lib/minio partition
#
#   Group 01–06 — platform services
#     01-cloudnativepg         Postgres operator
#     02-spire-bootstrap-ca    SPIRE upstream CA bootstrap
#     02-spire                 SPIRE server + agent + CSI driver
#     03-keycloak              Keycloak operator + DB + CR + ingress
#     04-spicedb               SpiceDB operator + DB + cluster
#     05-openbao               OpenBao seal + main + bootstrap secret
#     05a-openbao-bootstrap-seal      operator-step: capture seal Shamir keys
#     05b-openbao-bootstrap-main      operator-step: capture main Recovery + root keys
#     05c-openbao-configure    OpenBao Layer 1 (policies, kv-v2, transit, k8s auth)
#     05d-vso-install          Vault Secrets Operator
#     05e-vso-configure        VSO operator-self K8s auth role
#     05f-openbao-jwt-auth     OpenBao JWT-SPIFFE auth method
#     05g-keycloak-realms      operator-step: import platform realm
#     05h-keycloak-openbao-client      Keycloak openbao OIDC client
#     05i-openbao-oidc-auth    OpenBao OIDC auth method federated to Keycloak
#     05j-spicedb-vso-migration        SpiceDB → VSO config rendering
#     06-istio                 Istio Ambient (base + istiod + cni + ztunnel + PA)
#
#   Group 07 — observability
#     07-wazuh                 Wazuh manager + indexer + dashboard
#     07a-minio                MinIO + bucket bootstrap
#     07b-tempo                Tempo + scoped MinIO user
#     07c-otel-collector       OpenTelemetry Collector
#     07d-keycloak-grafana-client      Keycloak grafana OIDC client
#     07e-prometheus           kube-prometheus-stack
#     07f-loki                 Loki + scoped MinIO user
#     07g-promtail             Promtail
#     07h-grafana-datasources  Tempo + Loki datasources
#     07i-keycloak-wazuh-client         Keycloak wazuh-dashboard OIDC client
#     07j-wazuh-oidc-configure          Wazuh OIDC + indexer security config
#     07k-wazuh-k8s-group               Wazuh k8s agent-group + shared agent.conf
#     07l-wazuh-upstream-image-rules    upstream-image-check rules + Maintenance dashboard
#     07m-wazuh-maintenance-rules       OpenBao/cert-manager/CNPG/Velero maintenance rules
#     07n-wazuh-k3s-audit-decoder       k3s API-audit claim decoder
#     07o-wazuh-audit-rules             OpenBao + Keycloak audit decoder + rules
#     07p-wazuh-alerts-retention        ISM retention policy for wazuh-alerts-* indices
#     07q-grafana-dashboards            SecForge custom Grafana dashboards
#
#   Group 09 — backups
#     09a-velero               Velero
#     09b-cnpg-backups         CNPG backup config + ScheduledBackups
#     09c-velero-tune          PV-backup exclusions
#     09d-restore-drill        operator-runnable: validates the backup pipeline
#
#   Group 11 — host-resident agents
#     11-wazuh-host-agent      systemd-installed Wazuh agent (replaces 07b-wazuh-agent)
#
#   Group 12 — admission policy + governance
#     12-kyverno               Kyverno admission engine (HA)
#     12b-kyverno-policies     ClusterPolicies (PSS, image-signature, etc.)
#     12c-kyverno-image-verify-creds
#                              GHCR read credential for image verification
#
#   Per-app — instantiation, not in install-all
#     bootstrap-app.sh         takes APP_* env vars; instantiates the
#                              app-namespace template per app
#
# Operator-step components are marked with comments — they require
# manual interaction (root token paste, realm role assignment, etc.)
# and won't auto-run in a fully-headless install. Re-run the script
# after each operator step.
#
# Idempotent — every component re-runs cleanly. Safe to invoke after
# any partial failure.
#
# Usage:
#   bash platform/install-all.sh                # all components
#   bash platform/install-all.sh 00 00b 00c     # specific components only

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
COMPONENTS_DIR="$SCRIPT_DIR/components"

# Explicit ordering — DO NOT rely on lexicographic sort. Some components
# look identical alphabetically but have hard dependencies (e.g., 12
# Kyverno must come AFTER namespaces it might validate; 09a Velero
# requires 07a MinIO; etc.).
COMPONENT_ORDER=(
  # Host + cluster foundations
  00-host-bootstrap
  00b-cert-manager
  00c-ingress-nginx
  00d-wazuh-storage               # must run before 07-wazuh
  00e-minio-storage               # must run before 07a-minio

  # Platform services
  01-cloudnativepg
  02-spire-bootstrap-ca
  02-spire
  03-keycloak
  04-spicedb
  05-openbao
  05a-openbao-bootstrap-seal      # operator-step (interactive)
  05b-openbao-bootstrap-main      # operator-step (interactive)
  05c-openbao-configure
  05d-vso-install
  05e-vso-configure
  05f-openbao-jwt-auth
  05g-keycloak-realms             # operator-step
  05h-keycloak-openbao-client
  05i-openbao-oidc-auth
  05j-spicedb-vso-migration
  06-istio

  # Observability
  07-wazuh
  07a-minio
  07b-tempo
  07c-otel-collector
  07d-keycloak-grafana-client
  07e-prometheus
  07f-loki
  07g-promtail
  07h-grafana-datasources
  07i-keycloak-wazuh-client
  07j-wazuh-oidc-configure
  07k-wazuh-k8s-group
  07l-wazuh-upstream-image-rules
  07m-wazuh-maintenance-rules
  07n-wazuh-k3s-audit-decoder
  07o-wazuh-audit-rules
  07p-wazuh-alerts-retention
  07q-grafana-dashboards

  # Backups
  09a-velero
  09b-cnpg-backups
  09c-velero-tune

  # Host-resident agents
  11-wazuh-host-agent

  # Governance
  12-kyverno
  12b-kyverno-policies
  12c-kyverno-image-verify-creds
  12d-system-netpols              # default-deny netpols for kube-system/istio/topolvm (H-4.14)
)

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=("${COMPONENT_ORDER[@]}")
fi

for c in "${TARGETS[@]}"; do
  script="$COMPONENTS_DIR/$c.sh"
  if [ ! -x "$script" ]; then
    red "SKIP: $c.sh not found or not executable"
    continue
  fi
  green ""
  green "════════════════════════════════════════════════"
  green "==> $c"
  green "════════════════════════════════════════════════"
  "$script"
done
