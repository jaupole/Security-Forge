# Operational Runbooks

Step-by-step procedures for routine and emergency operations. These are populated incrementally as each phase builds the corresponding component.

Each runbook should have:
1. **Scope** — what scenario it covers
2. **Prerequisites** — what you need before starting (access, tools, etc.)
3. **Procedure** — numbered steps
4. **Validation** — how do you know it worked
5. **Recovery** — what to do if it doesn't work
6. **Last tested** — date

## Expected runbooks (created during the corresponding phases)

| File | Created in | Purpose |
|---|---|---|
| `incident-response.md` | Phase 7 | General on-call playbook |
| `key-rotation.md` | Phase 1 / 3 | KMS keys, realm signing keys, OpenBao recovery |
| `backup-and-restore.md` | Phase 1 | RDS, OpenBao, Wazuh data |
| `breaking-glass.md` | Phase 8 | Emergency admin access |
| [`spire-rotation.md`](./spire-rotation.md) | Phase 2 | SPIRE operational rotation, troubleshooting, recovery |
| [`spire-ca-rotation.md`](./spire-ca-rotation.md) | Phase 2 | SPIRE upstream CA rotation (every ~9 years) |
| `keycloak-operations.md` | Phase 3 | Realm management, user lockout recovery |
| `realm-signing-key-rotation.md` | Phase 3 | 90-day key rotation procedure |
| `spicedb-operations.md` | Phase 4 | Schema migration, data corruption recovery |
| `openbao-recovery.md` | Phase 5 | Recovery key use, quorum loss |
| `openbao-policy-changes.md` | Phase 5 | PR/review process for policy changes |
| [`bff-operations.md`](./bff-operations.md) | Phase 6 | BFF debugging |
| [`istio-authz.md`](./istio-authz.md) | Phase 6 | AuthorizationPolicy patterns |
| `observability.md` | Phase 7 | Adding dashboards, tuning alerts |
| `teleport-operations.md` | Phase 8 | Teleport admin tasks |
| `teleport-break-glass.md` | Phase 8 | Bootstrap admin recovery |
| `access-request-procedure.md` | Phase 8 | Production access workflow |
| `helloworld-deployment.md` | Phase 9 | Demo app deployment |

## Quarterly habit

Once a quarter, walk through every runbook end-to-end (in dev or staging, never directly in prod for the first time). Update the "last tested" date. Fix anything that's drifted from reality.

If a runbook hasn't been tested in 6 months, treat it as broken until proven otherwise.
