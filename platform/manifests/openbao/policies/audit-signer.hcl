# audit-signer — bound to k8s SAs that produce signed audit-anchor checkpoints
# (currently `member-hub/member-hub-audit-signer`, future apps follow the
# same pattern).
#
# Sign-only: can produce Ed25519 signatures with the `audit-signing` Transit
# key but cannot read the private material, rotate the key, or call any other
# Transit operation. Public-key read is allowed so the signer can include
# the key version + pubkey alongside each signature for verifier-friendliness.
#
# Bound via the kubernetes auth method's `*-audit-signer` roles (see
# 05j-app-vso-roles.sh). TTL is short (15m / 30m max) by design — anchor
# CronJobs run on a slow cadence and shouldn't keep tokens around.
#
# Codifies the live policy that previously existed only in-cluster from the
# 2026-05-22 Member Hub Phase B deploy (backlog item #11 close).

path "transit/sign/audit-signing" {
  capabilities = ["create", "update"]
}
path "transit/sign/audit-signing/*" {
  capabilities = ["create", "update"]
}
# Public key lookup so the signer can include the key version + pubkey
# in the anchor commit alongside the signature (verifier-friendliness).
path "transit/keys/audit-signing" {
  capabilities = ["read"]
}
