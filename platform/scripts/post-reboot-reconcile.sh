#!/usr/bin/env bash
# post-reboot-reconcile.sh — single-node reboot recovery for secforge-prod.
#
# Run this ON THE BOX after a host reboot/power-cycle, AFTER unsealing OpenBao
# (./openbao-unseal.sh). It codifies the manual recovery from the 2026-06-05
# reboot-storm incident so a reboot is a known 5-minute drill, not an outage.
#
# It is idempotent and read-only by default except step 2 (ambient restart,
# which is always safe + necessary). Destructive fixes are opt-in:
#   --reissue   delete stale-CA tls secrets so cert-manager re-issues them
#   --bounce    force-delete CrashLoopBackOff/Error/Unknown pods
#
# Why each step (see project_single_node_reboot_recovery + the runbook
# docs/03-runbooks/k3s-encryption-reenable.md §4):
#   1. OpenBao seal gate — main tier + all apps block until the seal is unsealed.
#   2. Istio ambient drift — pods that restarted during CNI recovery lose their
#      ztunnel HBONE path → DB/mTLS "terminate unexpectedly"; restart cni+ztunnel.
#   3. Stale-CA certs — a CA rotation can leave leaf serving-certs on a dead CA
#      (the spicedb-grpc-tls landmine); consumers fail "unable to verify cert".
#   4. Crash-loopers / node-lost pods — surface + optionally bounce.
#
# kubectl: uses your shell's kubeconfig. Override with KUBECTL='sudo kubectl'.
set -uo pipefail

KUBECTL="${KUBECTL:-kubectl}"
REISSUE=0; BOUNCE=0
for a in "$@"; do
  case "$a" in
    --reissue) REISSUE=1 ;;
    --bounce)  BOUNCE=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a (try --help)"; exit 2 ;;
  esac
done

grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
yel(){ printf '\033[33m%s\033[0m\n' "$*"; }
red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
hr(){ printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }

hr "0. node / control-plane"
if ! $KUBECTL get node >/dev/null 2>&1; then
  red "kubectl can't reach the API. Is k3s up? Try: KUBECTL='sudo kubectl' $0"
  exit 1
fi
$KUBECTL get node -o wide 2>/dev/null | awk 'NR==1 || /secforge/'

hr "1. OpenBao seal gate"
if $KUBECTL -n openbao get pod openbao-seal-0 >/dev/null 2>&1; then
  sealed=$($KUBECTL -n openbao exec openbao-seal-0 -c openbao -- bao status -tls-skip-verify 2>/dev/null | awk '/^Sealed/{print $2}')
  if [ "$sealed" = "true" ]; then
    red "openbao-seal is SEALED — unseal it FIRST, then re-run:  ./openbao-unseal.sh"
    red "(main tier openbao-0/1/2 + every app stays broken until then)"
  else
    grn "openbao-seal unsealed; main tier:"
    $KUBECTL -n openbao get pods --no-headers 2>/dev/null | grep -E 'openbao-[0-9]' || true
  fi
else
  yel "openbao-seal-0 not found (skipping seal gate)"
fi

hr "2. Istio ambient reconcile (fixes post-reboot ztunnel HBONE drift)"
$KUBECTL -n istio-system rollout restart ds/istio-cni-node ds/ztunnel 2>&1 | sed 's/^/  /'
$KUBECTL -n istio-system rollout status ds/istio-cni-node --timeout=120s 2>&1 | tail -1
$KUBECTL -n istio-system rollout status ds/ztunnel --timeout=120s 2>&1 | tail -1
# gateways re-fetch the mesh root via SDS on restart — cheap insurance if istiod regenerated its CA
$KUBECTL -n istio-ingress rollout restart deploy 2>/dev/null | sed 's/^/  /' || true
grn "ambient reconciled"

hr "3. Stale-CA scan (leaf certs not signed by the canonical internal CA)"
CANON=$($KUBECTL -n cert-manager get secret secforge-internal-ca-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
        | base64 -d 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')
if [ -z "$CANON" ]; then
  yel "could not read canonical internal CA (cert-manager/secforge-internal-ca-tls) — skipping scan"
else
  echo "canonical internal CA = $CANON"
  stale=0
  while read -r ns name; do
    [ -z "${name:-}" ] && continue
    ca=$($KUBECTL -n "$ns" get secret "$name" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d 2>/dev/null) || continue
    [ -z "$ca" ] && continue
    case "$(printf '%s' "$ca" | openssl x509 -noout -subject 2>/dev/null)" in
      *"SecForge Internal CA"*)
        fp=$(printf '%s' "$ca" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')
        if [ -n "$fp" ] && [ "$fp" != "$CANON" ]; then
          red "  STALE  $ns/$name  (ca=$fp)"
          stale=$((stale+1))
          if [ "$REISSUE" = 1 ]; then
            yel "    re-issuing: delete secret -> cert-manager recreates from clusterissuer"
            $KUBECTL -n "$ns" delete secret "$name" 2>&1 | sed 's/^/    /'
            yel "    NOTE: restart the consumer of $ns/$name to load the new cert"
          else
            echo "    fix: $KUBECTL -n $ns delete secret $name   # then restart that workload"
          fi
        fi ;;
    esac
  done < <($KUBECTL get secret -A --field-selector type=kubernetes.io/tls \
            -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null)
  [ "$stale" = 0 ] && grn "no stale-CA certs" \
    || yel "$stale stale cert(s) — re-run with --reissue, then restart those workloads"
fi

hr "4. Not-ready / crash-looping pods"
notready=$($KUBECTL get pods -A --no-headers 2>/dev/null | grep -ivE 'Running|Completed' || true)
if [ -z "$notready" ]; then
  grn "all pods Running/Completed"
else
  echo "$notready"
  if [ "$BOUNCE" = 1 ]; then
    echo "$notready" | awk '$4 ~ /CrashLoopBackOff|Error|Unknown/ {print $1, $2}' \
      | while read -r ns pod; do
          yel "  bouncing $ns/$pod"
          $KUBECTL -n "$ns" delete pod "$pod" --force --grace-period=0 >/dev/null 2>&1 || true
        done
  else
    echo "  (re-run with --bounce to force-delete CrashLoopBackOff/Error/Unknown pods)"
  fi
fi

hr "5. Health summary"
$KUBECTL get pods -A --no-headers 2>/dev/null | awk '{print $4}' | sort | uniq -c
if command -v k3s >/dev/null 2>&1; then
  echo "encryption: $(sudo -n k3s secrets-encrypt status 2>/dev/null | awk -F': ' '/Encryption Status/{print $2}')"
fi
grn "reconcile complete"
