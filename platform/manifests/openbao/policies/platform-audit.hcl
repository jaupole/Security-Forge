# platform-audit — read-only access to the GitHub PAT used by the platform
# audit-anchor CronJob (manifests/openbao/12-platform-audit-anchor.yaml) to push
# signed anchors to jaupole/secforge-audit-anchors. Paired with the `audit-signer`
# policy (transit/sign) on the `platform-audit-signer` k8s-auth role (05j).
#
# The PAT is provisioned once by the operator (needs OpenBao admin):
#   bao kv put secret/platform/audit-anchors-push-token token=<fine-grained PAT,
#     contents:write on jaupole/secforge-audit-anchors>
# (reuse the existing Member Hub PAT value or mint a platform-scoped one.)

path "secret/data/platform/audit-anchors-push-token" {
  capabilities = ["read"]
}
