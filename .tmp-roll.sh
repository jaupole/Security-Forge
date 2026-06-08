set -e
P="$1"
echo ">>> rolling $P (delete; STS recreates with audit volume)"
sudo -n kubectl -n openbao delete pod "$P" --timeout=120s
echo ">>> waiting for $P Ready + unsealed (init containers + transit auto-unseal)"
for i in $(seq 1 42); do
  ready=$(sudo -n kubectl -n openbao get pod "$P" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo false)
  if [ "$ready" = "true" ]; then break; fi
  sleep 5
done
sudo -n kubectl -n openbao get pod "$P" -o wide 2>/dev/null | grep -E "NAME|$P"
echo ">>> sealed status:"
sudo -n kubectl -n openbao exec "$P" -c openbao -- env BAO_SKIP_VERIFY=1 bao status -format=json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print('   sealed=%s is_self=%s version=%s'%(d.get('sealed'),d.get('is_self'),d.get('version')))"
echo ">>> audit PVC + /openbao/audit mount:"
sudo -n kubectl -n openbao get pvc "audit-$P" 2>/dev/null | grep -E "audit-$P"
sudo -n kubectl -n openbao exec "$P" -c openbao -- ls -ld /openbao/audit 2>/dev/null
echo ">>> Raft peers (quorum check):"
sudo -n kubectl -n openbao exec "$P" -c openbao -- env BAO_SKIP_VERIFY=1 bao operator raft list-peers 2>/dev/null | tail -5 || echo "   (list-peers needs auth; skipping)"
