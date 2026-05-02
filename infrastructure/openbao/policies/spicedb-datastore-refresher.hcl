# spicedb-datastore-refresher — bound to
# spiffe://secforge.local/ns/spicedb/sa/spicedb-datastore-refresher
# via the JWT auth method's spicedb-datastore-refresher role.
#
# Policy scope: the 12-hourly CronJob (Phase 7d.2.c, ADR-0023) that
# composes a fresh K8s Secret content from the database engine + the
# static PSK and writes it to secret/data/spicedb/config so VSO's
# existing VaultStaticSecret renders it.
#
# Capabilities the CronJob needs:
#   - mint a fresh dynamic credential from the database engine
#     (read on database/creds/spicedb-readwrite — minting a cred is a
#     read operation in OpenBao's API model)
#   - read the static PSK to compose into the config Secret
#   - write a new KV-v2 version at the config path

# Mint dynamic Postgres credentials.
path "database/creds/spicedb-readwrite" {
  capabilities = ["read"]
}

# Read the AuthZEN-shared PSK path (same path used by AuthZEN's VSO
# binding; PSK rotation is a separate concern handled outside 7d).
path "secret/data/spicedb/preshared-key" {
  capabilities = ["read"]
}
path "secret/metadata/spicedb/preshared-key" {
  capabilities = ["read"]
}

# Compose + write the unified config used by SpiceDB Operator.
path "secret/data/spicedb/config" {
  capabilities = ["read", "create", "update"]
}
path "secret/metadata/spicedb/config" {
  capabilities = ["read"]
}
