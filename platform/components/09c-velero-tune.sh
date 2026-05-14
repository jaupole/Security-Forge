#!/usr/bin/env bash
# 09c — Annotate workloads to exclude their PVs from Velero file-system backup.
#
# Why: see manifests/velero/04-pv-backup-exclusions.yaml header.
#
# Idempotent. Re-runnable as more workloads are added.

set -euo pipefail

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# MinIO (recursion: Velero backups land in MinIO)
green "==> minio: exclude export volume from Velero PV backup"
kubectl -n minio patch deployment minio --type=strategic -p '{
  "spec": {
    "template": {
      "metadata": {
        "annotations": {
          "backup.velero.io/backup-volumes-excludes": "export"
        }
      }
    }
  }
}' 2>&1 | tail -1

# Wazuh indexer (large data dir; recoverable by filebeat replay of alerts.json)
green "==> wazuh-indexer: exclude wazuh-indexer-data volume from Velero PV backup"
# Indexer is a StatefulSet wrapped by chart; volume name is `wazuh-indexer-data`.
kubectl -n wazuh patch statefulset wazuh-indexer --type=strategic -p '{
  "spec": {
    "template": {
      "metadata": {
        "annotations": {
          "backup.velero.io/backup-volumes-excludes": "wazuh-indexer-data"
        }
      }
    }
  }
}' 2>&1 | tail -1

# Wazuh manager (large data dir; ~11G is the CVE feed cache in queue/vd/feed,
# upstream-derivable in minutes. The remaining 3-4G is alert archives + queue;
# alert archives are also shipped to the wazuh-archive MinIO bucket for
# longer retention. The manager ConfigMap (rules, decoders, ossec.conf) is
# still backed up at the K8s resource level — only the PV blob is excluded.)
green "==> wazuh-manager: exclude wazuh-manager-data volume from Velero PV backup"
kubectl -n wazuh patch statefulset wazuh-manager --type=strategic -p '{
  "spec": {
    "template": {
      "metadata": {
        "annotations": {
          "backup.velero.io/backup-volumes-excludes": "wazuh-manager-data"
        }
      }
    }
  }
}' 2>&1 | tail -1

# CloudNativePG cluster pods. CNPG has its own Barman backup → MinIO; no
# need for Velero to also kopia-snapshot the pgdata PV.
# CNPG accepts annotations via spec.managed.podMetadata.
for entry in "keycloak:secforge-keycloak-db" "spicedb:secforge-spicedb-db"; do
  ns="${entry%%:*}"; cluster="${entry##*:}"
  green "==> $ns/$cluster: exclude pgdata volume from Velero PV backup"
  kubectl -n "$ns" patch cluster.postgresql.cnpg.io "$cluster" --type=merge -p '{
    "spec": {
      "managed": {
        "podMetadata": {
          "annotations": {
            "backup.velero.io/backup-volumes-excludes": "pgdata"
          }
        }
      }
    }
  }' 2>&1 | tail -1
done

# Observability stack — Loki/Tempo/Prometheus data is recoverable via
# replay or short-window acceptable loss. Grafana state is in ConfigMaps
# (datasources + dashboards via sidecar). Skip PV backups for all.
green "==> observability: exclude data volumes for loki, tempo, prometheus, grafana"
kubectl -n observability patch statefulset loki --type=strategic -p '{
  "spec": {"template": {"metadata": {"annotations": {"backup.velero.io/backup-volumes-excludes": "storage"}}}}}' 2>&1 | tail -1 || yellow "    loki: not found"
kubectl -n observability patch statefulset tempo --type=strategic -p '{
  "spec": {"template": {"metadata": {"annotations": {"backup.velero.io/backup-volumes-excludes": "storage"}}}}}' 2>&1 | tail -1 || yellow "    tempo: not found"
kubectl -n observability patch statefulset prometheus-kps-prometheus --type=strategic -p '{
  "spec": {"template": {"metadata": {"annotations": {"backup.velero.io/backup-volumes-excludes": "prometheus-kps-prometheus-db"}}}}}' 2>&1 | tail -1 || yellow "    prometheus: not found"
kubectl -n observability patch deployment kps-grafana --type=strategic -p '{
  "spec": {"template": {"metadata": {"annotations": {"backup.velero.io/backup-volumes-excludes": "storage"}}}}}' 2>&1 | tail -1 || yellow "    grafana: not found"

cat <<'EOF'

✓ Velero PV backup exclusions applied.

Verify on the next backup:
  kubectl -n velero get backup
  kubectl -n velero get podvolumebackup     # should NOT include pgdata, export, indexer-data, etc.

Inspect MinIO size shrink after the next scheduled backup runs:
  kubectl -n minio exec deploy/minio -- sh -c 'mc du local/backups/velero'

The K8s resources (Deployments, Services, Secrets, ConfigMaps,
Cluster CRs) are still backed up — only PV blob contents are excluded
for these specific workloads.
EOF
