#requires -Version 5.1
<#
Starts the local-dev SpiceDB binary against the local Postgres datastore.
Use this instead of running spicedb.exe by hand so the connection flags stay consistent.

Datastore: postgres on localhost:5432, database 'spicedb_dev', user 'proposalforge'.
Schema/relationships persist across restarts (unlike --datastore-engine=memory).

To bring up the schema after a fresh DB:
  & "$PSScriptRoot/bin/zed.exe" --endpoint=localhost:50051 --token=local-dev-key --insecure schema write "$PSScriptRoot/../infrastructure/spicedb/ecosystem-schema.zed"
#>

$ErrorActionPreference = 'Stop'

$binary = Join-Path $PSScriptRoot 'bin\spicedb.exe'
$connUri = 'postgres://proposalforge:proposalforge@localhost:5432/spicedb_dev?sslmode=disable'

if (-not (Test-Path $binary)) {
    throw "spicedb.exe not found at $binary"
}

& $binary serve `
    --grpc-preshared-key=local-dev-key `
    --datastore-engine=postgres `
    --datastore-conn-uri=$connUri `
    --skip-release-check
