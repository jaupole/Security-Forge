# Audit owner separation — runbook

Proposal Forge, Business Manager and Project Manager keep tamper-evident audit logs. Until this
change, each app's **login role owned its own audit objects**: the table, the functions behind the
append-only triggers, and the schema they live in. Whoever held the app's database password could
disable a trigger, replace a guard function, or drop and recreate the table, and recompute the hash
chain as they went. The copy in Control and the off-site anchor would still expose it, but the local
protection was only as strong as the app's own restraint.

## What it does

Per app, the audit objects move to a role **nobody can log in as or `SET ROLE` to**:

| Database | Owner role | What moves | What the app keeps |
|---|---|---|---|
| `proposal_forge` | `proposal_forge_audit_owner` | `audit_log`, its sequence, every `audit_log_*` function, schema `public` | SELECT, INSERT, gated DELETE on the table; CREATE in the schema |
| `business_manager` | `business_manager_audit_owner` | `audit_logs`, its sequence, every `audit_logs_*` function, schema `business_manager` | SELECT, INSERT, gated DELETE on the table; CREATE in the schema |
| `project_manager` | `project_manager_audit_owner` | schema `audit` and every table, sequence and function in it | `project_manager_app` keeps its existing grants unchanged |

"Gated DELETE" is the retention purge: only with the purge flag on, and only rows past their
retention, checked row by row by the delete guard.

The schema moves too because a schema's owner may drop any object in it, whoever owns the object.
The apps keep CREATE in the schema, so every other migration works as before.

Only the in-pod `postgres` superuser can act on the audit objects afterwards. That includes setting
Project Manager's `audit.tamper_flag`.

## Apply

Prerequisite: each app is already running its last audit migration (the scripts refuse otherwise):
Proposal Forge `20261006190000_audit_log_delete_guard`, Business Manager
`20261006163000_audit_log_delete_guard`, Project Manager `035_audit_retention`.

```bash
cd ~/secforge && git pull --ff-only
sudo -n bash platform/components/09j-audit-owner-separation.sh
# expect three lines:  NOTICE:  OK  <db>: … owned by <db>_audit_owner
```

Each script runs in one transaction and ends with a posture check that raises (and rolls the whole
script back) if anything is off. It takes a brief exclusive lock on the audit table; apps need no
restart. Then confirm each app still writes audit rows:

```bash
PSQL="sudo -n kubectl exec -n ecosystem-db ecosystem-db-1 -c postgres -- psql -U postgres -qAt"
$PSQL -d proposal_forge   -c "SELECT max(created_at) FROM audit_log"
$PSQL -d business_manager -c "SELECT max(created_at) FROM business_manager.audit_logs"
$PSQL -d project_manager  -c "SELECT max(ts) FROM audit.event"
# and no errors in the app logs after the next user action:
sudo -n kubectl -n proposal-forge logs deploy/proposal-forge --since=10m | grep -i "audit\|permission denied"
```

Re-running the script is the periodic check: it is idempotent and re-verifies the posture.

## Shipping a migration that touches the audit objects

The app's migration Job can no longer alter them ("must be owner"). Each app repo has a test
(`audit-ownership.test.ts` / `ownership.test.ts`) that fails the build when a new migration mentions
them, so this is caught before deploy, not during it. When such a migration is really needed:

```bash
# 1. In the app repo: add the migration's name to APPLIED_BY_SUPERUSER in that test, merge, build.
# 2. Lend the objects back to the app, for that one database:
sudo -n bash ~/secforge/platform/components/09j-audit-owner-separation.sh --lend proposal_forge
# 3. Deploy the app as usual (the migration Job applies the migration).
# 4. Take ownership back and re-check the posture:
sudo -n bash ~/secforge/platform/components/09j-audit-owner-separation.sh proposal_forge
```

Keep the window between 2 and 4 short: while lent, the app's credentials can again switch the
protection off. The take-back picks up any new `audit_log_*` function by name.

## Roll back

`--lend` is the rollback. It returns ownership to the app's role and leaves the (now unused) owner
role in place. Nothing else needs undoing; the grants the script added are a subset of what an owner
has anyway.

```bash
sudo -n bash ~/secforge/platform/components/09j-audit-owner-separation.sh --lend proposal_forge business_manager project_manager
```

## If an app starts failing after the apply

| Symptom | Likely cause | Do |
|---|---|---|
| `permission denied for table audit_log` / `audit_logs` on an INSERT or SELECT | A grant did not land | Re-run the script for that database; the posture check names what is missing |
| `permission denied for sequence …` | Same, for the sequence | Same |
| `must be owner of …` during a deploy's migration Job | A migration touches the audit objects | The lend / deploy / take-back steps above |
| `permission denied for schema …` creating a table in a migration | The app lost CREATE in the schema | Re-run the script |
| Project Manager: every audited write fails in `audit.set_full_hash` | `audit.event` was switched to FORCE row security | Do not: the script refuses in that state. `ALTER TABLE audit.event NO FORCE ROW LEVEL SECURITY` as superuser |

If in doubt, `--lend` for that database restores the previous behaviour at once.

## Disaster recovery

The owner roles are cluster roles and ownership is in the catalog, so both come back with a physical
(barman) restore. After any logical restore or rebuild of a database, re-run the script for it: it
recreates the role if missing and re-applies ownership.

## Limits

- This protects the audit objects from the **app's** credentials. The in-pod superuser can still do
  anything; that is what the Control copy and the off-site anchors
  (`control-audit-anchor.md`) are for.
- Each app is still the owner of its **database**. It cannot touch the audit objects through that,
  but it could drop the whole database. That is an availability risk covered by backups, not an
  integrity one.
- Project Manager's login role keeps `BYPASSRLS`, unchanged. It no longer has any privilege on
  schema `audit` beyond what `project_manager_app` has.
