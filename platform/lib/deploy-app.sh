#!/usr/bin/env bash
# Deploy a first-party app from the COMMITTED manifests — git is the source
# of truth; the digest bump must already be pushed (deploy-app.yml does
# bump → commit → push → this). Runs as root (kubectl); reads the ops
# clone, exactly like the manual `sudo bash lib/apply-manifest.sh` flow.
#
# Invoked by /usr/local/sbin/secforge-app-deploy, the sudoers-gated entry
# point for the github-runner account (see deploy-app.yml). The runner can
# only trigger "deploy what main says for app X" — it cannot supply
# manifests, digests, or flags. Direct operator use also works:
#   sudo bash platform/lib/deploy-app.sh control
#
# Flow: find the app's digest-pinned manifests → delete stale one-shot
# migration Job (fixed name, immutable template — Security-Forge#36) →
# apply migration + wait complete (logs on failure) → apply the remaining
# manifests → rollout status per Deployment (readiness probes are the
# smoke test) → on rollout failure: rollout undo + dump Kyverno/pod
# events + exit 1 (deploy-app.yml then reverts the git bump).
set -euo pipefail

APP="${1:?usage: deploy-app.sh <app>}"

# app → manifest dir, GHCR image short name, migration manifest (empty =
# none), Deployment names, namespace. Keep in sync with deploy-app.yml's
# `app` choice list and /etc/sudoers.d/github-runner-deploy.
case "$APP" in
  control)          DIR=control;          IMAGE=control;          MIGRATE=08-migration-job.yaml; DEPLOYS="control";          NS=control ;;
  portal)           DIR=control;          IMAGE=portal;           MIGRATE="";                    DEPLOYS="portal";           NS=control ;;
  member-hub)       DIR=member-hub;       IMAGE=member-hub;       MIGRATE=08-migration-job.yaml; DEPLOYS="member-hub";       NS=member-hub ;;
  proposal-forge)   DIR=proposal-forge;   IMAGE=proposal-forge;   MIGRATE=08-migration-job.yaml; DEPLOYS="proposal-forge";   NS=proposal-forge ;;
  business-manager) DIR=business-manager; IMAGE=business-manager; MIGRATE=08-migration-job.yaml; DEPLOYS="business-manager"; NS=business-manager ;;
  project-manager)  DIR=project-manager;  IMAGE=project-manager;  MIGRATE=08-migration-job.yaml; DEPLOYS="project-manager";  NS=project-manager ;;
  document-render)  DIR=document-render;  IMAGE=gotenberg;        MIGRATE="";                    DEPLOYS="gotenberg";        NS=document-render ;;
  *) echo "ERR: unknown app '$APP'" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
MANIFEST_DIR="$PLATFORM_DIR/manifests/$DIR"
APPLY="$SCRIPT_DIR/apply-manifest.sh"

# The manifests that pin THIS app's image — the set deploy-app.yml bumped.
# Keyed on the image name, not the dir: portal shares manifests/control/.
mapfile -t FILES < <(grep -l "image: ghcr.io/jaupole/$IMAGE@" "$MANIFEST_DIR"/*.yaml)
(( ${#FILES[@]} > 0 )) || { echo "ERR: no manifests pin ghcr.io/jaupole/$IMAGE in $MANIFEST_DIR" >&2; exit 1; }

DIGEST=$(grep -hoE "ghcr.io/jaupole/$IMAGE@sha256:[a-f0-9]{64}" "${FILES[0]}" | head -1)
echo ">>> deploying $APP from git: $DIGEST"
echo ">>> manifests: ${FILES[*]##*/}"

# 1. Migration job first — fixed-name one-shot with an immutable template,
#    so the previous Job must go before re-apply (Security-Forge#36).
REST=()
for f in "${FILES[@]}"; do
  if [[ -n "$MIGRATE" && "${f##*/}" == "$MIGRATE" ]]; then
    JOB=$(grep -m1 -A2 "^kind: Job" "$f" | grep -m1 "name:" | awk '{print $2}')
    echo ">>> migration job: $JOB"
    kubectl delete job -n "$NS" "$JOB" --ignore-not-found
    bash "$APPLY" "$f"
    if ! kubectl wait --for=condition=complete "job/$JOB" -n "$NS" --timeout=300s; then
      echo "ERR: migration job did not complete — logs:" >&2
      kubectl logs -n "$NS" "job/$JOB" --tail=40 >&2 || true
      exit 1
    fi
    kubectl logs -n "$NS" "job/$JOB" --tail=5 || true
  else
    REST+=("$f")
  fi
done

# 2. Everything else (Deployments + CronJobs sharing the image).
(( ${#REST[@]} == 0 )) || bash "$APPLY" "${REST[@]}"

# 3. Rollout gate — the Deployments' readiness probes are the smoke test.
#    A Kyverno admission denial (e.g. unsigned image) surfaces here as a
#    timeout; undo so the cluster never sits on a half-rolled state.
for d in $DEPLOYS; do
  if ! kubectl rollout status "deploy/$d" -n "$NS" --timeout=180s; then
    echo "ERR: rollout of deploy/$d failed — undoing. Recent events:" >&2
    kubectl get events -n "$NS" --sort-by=.lastTimestamp 2>/dev/null | tail -12 >&2 || true
    kubectl rollout undo "deploy/$d" -n "$NS" >&2 || true
    kubectl rollout status "deploy/$d" -n "$NS" --timeout=120s >&2 || true
    exit 1
  fi
done

echo ">>> $APP deployed: $DIGEST"
