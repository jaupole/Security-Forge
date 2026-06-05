#!/usr/bin/env bash
# openbao-unseal.sh — interactive Shamir unseal of the openbao-seal tier (3/5).
#
# Run ON THE BOX after a reboot. The seal tier deliberately uses Shamir (no
# auto-unseal of the root of trust on a self-hosted box), so this manual step
# is by design — this just makes it fast and safe. Once the seal tier unseals,
# the main tier (openbao-0/1/2) auto-unseals via Transit within ~30-60s.
#
# SECURITY: each key share is read at a HIDDEN prompt and piped to
# `bao operator unseal -` over stdin — it never appears in argv, the process
# list, shell history, or the host audit log.
#
# kubectl: uses your shell's kubeconfig. Override with KUBECTL='sudo kubectl'.
# Usage:  ./openbao-unseal.sh [seal-pod-name]   (default: openbao-seal-0)
set -uo pipefail

KUBECTL="${KUBECTL:-kubectl}"
POD="${1:-openbao-seal-0}"
NS=openbao

status(){ $KUBECTL -n "$NS" exec "$POD" -c openbao -- bao status -tls-skip-verify 2>/dev/null; }

if ! $KUBECTL -n "$NS" get pod "$POD" >/dev/null 2>&1; then
  echo "ERROR: pod $NS/$POD not found (is the cluster up? try KUBECTL='sudo kubectl')" >&2
  exit 1
fi

sealed=$(status | awk '/^Sealed/{print $2}')
if [ "$sealed" != "true" ]; then
  echo "$POD is already unsealed (Sealed=${sealed:-unknown}). Nothing to do."
  status | grep -E '^(Sealed|HA Mode)' || true
  exit 0
fi

thr=$(status | awk '/^Threshold/{print $2}'); thr="${thr:-3}"
echo "$POD is SEALED. Enter $thr unseal-key shares (input hidden)."
for i in $(seq 1 "$thr"); do
  printf 'Unseal key share %d/%d: ' "$i" "$thr"
  IFS= read -rs KEY; echo
  if [ -z "$KEY" ]; then echo "  (empty — skipping)"; continue; fi
  # pipe via stdin: the key is the '-' positional, read from stdin, never argv
  printf '%s' "$KEY" | $KUBECTL -n "$NS" exec -i "$POD" -c openbao -- \
    bao operator unseal -tls-skip-verify - 2>&1 | grep -E '^(Sealed|Unseal Progress)' || true
  KEY=
  if [ "$(status | awk '/^Sealed/{print $2}')" = "false" ]; then
    echo; echo "✓ $POD unsealed."
    break
  fi
done

echo
echo "final seal status:"
status | grep -E '^(Sealed|HA Mode|Initialized)' || true
echo
echo "Main tier auto-unseals via Transit. Watch it converge:"
echo "  $KUBECTL -n $NS get pods -w"
