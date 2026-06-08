set -e
echo "=== manifests present on box? ==="
ls -1 ~/secforge/platform/manifests/openbao/12-platform-audit-anchor.yaml \
      ~/secforge/platform/manifests/openbao/13-platform-audit-verifier.yaml \
      ~/secforge/platform/manifests/openbao/policies/platform-audit.hcl
echo "=== auditStorage in values (expect 10Gi) ==="
grep -A1 'auditStorage:' ~/secforge/platform/values/openbao.yaml | grep -E 'enabled|size'
echo "=== break-glass admin validation (read-only checks) ==="
sudo -n kubectl exec -n openbao openbao-0 -c openbao -- sh -c '
  export BAO_SKIP_VERIFY=1
  SA=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  T=$(bao write -field=token auth/kubernetes/login role=admin-break-glass jwt=$SA 2>/dev/null)
  if [ -z "$T" ]; then echo "BREAK-GLASS LOGIN FAILED"; exit 1; fi
  echo "break-glass: minted admin token (len ${#T})"
  BAO_TOKEN=$T bao token lookup 2>/dev/null | grep -E "^policies|^ttl"
  BAO_TOKEN=$T bao read -field=name transit/keys/audit-signing >/dev/null 2>&1 && echo "audit-signing key: present" || echo "audit-signing key: MISSING"
  echo "current audit devices:"
  BAO_TOKEN=$T bao audit list 2>/dev/null
  BAO_TOKEN=$T bao kv get -field=token secret/apps/member-hub/audit-anchors-push-token >/dev/null 2>&1 && echo "member-hub PAT source: present (reusable)" || echo "member-hub PAT source: MISSING"
  BAO_TOKEN=$T bao kv get secret/platform/audit-anchors-push-token >/dev/null 2>&1 && echo "platform PAT: already set" || echo "platform PAT: not set yet (expected)"
'
