# raft-snapshot — bound to the platform-raft-snapshot k8s-auth role (SA
# openbao/openbao-raft-snapshot). Lets the snapshot CronJob take application-
# consistent OpenBao Raft snapshots for DR (ADR-0020 / operator-backlog #96).
#
# Least-privilege: ONLY the snapshot read. No secret/, transit/, or policy
# access — a leaked snapshot token can copy the (seal-encrypted) datastore but
# cannot read plaintext secrets or mutate anything. `sudo` is required because
# sys/storage/raft/snapshot is a sudo-protected path in OpenBao.
path "sys/storage/raft/snapshot" {
  capabilities = ["read", "sudo"]
}
