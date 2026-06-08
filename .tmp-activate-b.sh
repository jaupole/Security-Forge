set -e
echo ">>> minting break-glass admin token + staging openbao-root-token-tmp (no root token needed)"
SA=$(sudo -n kubectl -n openbao exec openbao-0 -c openbao -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
T=$(sudo -n kubectl -n openbao exec openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 bao write -field=token auth/kubernetes/login role=admin-break-glass jwt="$SA")
[ -n "$T" ] || { echo "ERROR: break-glass mint failed"; exit 1; }
sudo -n kubectl -n openbao delete secret openbao-root-token-tmp --ignore-not-found >/dev/null 2>&1 || true
printf %s "$T" | sudo -n kubectl -n openbao create secret generic openbao-root-token-tmp --from-file=token=/dev/stdin >/dev/null
echo "   staged admin token (1h ttl)"
echo
echo ">>> running 05c (enable file audit device + load platform-audit policy) ..."
bash ~/secforge/platform/components/05c-openbao-configure.sh 2>&1 | grep -vE "^    policy:|already exists|already enabled" | tail -25
echo
echo ">>> audit devices now (expect stdout/ AND file/):"
sudo -n kubectl -n openbao exec openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$T" bao audit list 2>/dev/null
echo ">>> OpenBao still SERVING? (read a kv path):"
sudo -n kubectl -n openbao exec openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$T" bao kv list -format=json secret/metadata/platform >/dev/null 2>&1 && echo "   YES — kv read succeeded" || echo "   (kv list path empty/na — trying sys/health)"
sudo -n kubectl -n openbao exec openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 bao status >/dev/null 2>&1 && echo "   status OK"
echo
echo ">>> running 05j (platform-audit-signer role + apply 12/13 suspended manifests) ..."
bash ~/secforge/platform/components/05j-app-vso-roles.sh 2>&1 | tail -20
