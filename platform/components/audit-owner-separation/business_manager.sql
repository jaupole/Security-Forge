-- Audit owner separation — Business Manager (database business_manager).
--
-- WHY. The app's login role `business_manager` owned its own audit table, the
-- functions behind the append-only triggers, and schema business_manager.
-- Whoever holds the app's database password could therefore
--   ALTER TABLE audit_logs DISABLE TRIGGER …      (switch the protection off)
--   CREATE OR REPLACE FUNCTION audit_logs_block_mutate() …   (hollow it out)
--   DROP TABLE audit_logs                          (schema owner may drop any table)
-- and rewrite history, recomputing the hash chain as it went. The copy in
-- Control and the off-site anchor would still expose it, but the local
-- protection was only as strong as the app's own restraint.
--
-- WHAT. The audit table, its sequence, its functions and schema
-- business_manager move to `business_manager_audit_owner`: NOLOGIN, no
-- password, no members. Nobody can connect as it or SET ROLE to it; only the
-- in-pod superuser can act on those objects. The app keeps exactly what it
-- needs: SELECT, INSERT, and DELETE (retention only — still gated by the purge
-- flag, the retention policies and the row-level guard), plus CREATE in the
-- schema so its migrations keep working.
--
-- CONSEQUENCE. A future migration that alters audit_logs or its functions
-- cannot be applied by the app's migration Job any more ("must be owner").
-- Apply that one migration by hand as the in-pod superuser — see
-- docs/03-runbooks/audit-owner-separation.md. The app repo has a test that
-- fails the build when a new migration touches the audit table.
--
-- Run as the in-pod superuser:  psql -U postgres -d business_manager -f <this>
-- Idempotent: safe to re-run; the last block re-checks the posture each time.

\set ON_ERROR_STOP on
BEGIN;

-- Refuse unless the app's last audit migration is in. After this script the
-- app's migration Job can no longer alter these objects, so it must not be
-- run ahead of a migration that still needs to.
DO $$
BEGIN
  IF to_regprocedure('business_manager.audit_logs_guard_delete()') IS NULL THEN
    RAISE EXCEPTION 'deploy Business Manager with migration 20261006163000_audit_log_delete_guard first';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'business_manager_audit_owner') THEN
    CREATE ROLE business_manager_audit_owner
      NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION;
  END IF;
END $$;

-- The schema first: its owner may drop any object in it, whoever owns the object.
ALTER SCHEMA business_manager OWNER TO business_manager_audit_owner;
GRANT USAGE, CREATE ON SCHEMA business_manager TO business_manager;

-- The table. Its indexes and the sequence owned by audit_logs.id move with it.
ALTER TABLE business_manager.audit_logs OWNER TO business_manager_audit_owner;

-- Every audit_logs_* function: the seal, the guards, the hash, the classifier
-- and the verifier. Whoever owns a trigger's function can hollow the trigger out.
DO $$
DECLARE
  f regprocedure;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'business_manager' AND p.proname LIKE 'audit\_logs\_%'
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO business_manager_audit_owner', f);
  END LOOP;
END $$;

-- What the app keeps. No UPDATE, TRUNCATE, TRIGGER or REFERENCES.
REVOKE ALL ON business_manager.audit_logs FROM PUBLIC, business_manager;
GRANT SELECT, INSERT, DELETE ON business_manager.audit_logs TO business_manager;
REVOKE ALL ON SEQUENCE business_manager.audit_logs_id_seq FROM PUBLIC, business_manager;
GRANT USAGE ON SEQUENCE business_manager.audit_logs_id_seq TO business_manager;

-- ─── Posture check ───────────────────────────────────────────────────────────
DO $$
DECLARE
  r record;
BEGIN
  SELECT rolcanlogin, rolsuper, rolbypassrls, rolcreaterole INTO r
    FROM pg_roles WHERE rolname = 'business_manager_audit_owner';
  IF r.rolcanlogin OR r.rolsuper OR r.rolbypassrls OR r.rolcreaterole THEN
    RAISE EXCEPTION 'business_manager_audit_owner must be NOLOGIN, non-superuser, NOBYPASSRLS, NOCREATEROLE';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles o ON o.oid = m.roleid
              WHERE o.rolname = 'business_manager_audit_owner') THEN
    RAISE EXCEPTION 'business_manager_audit_owner has members: someone could SET ROLE to it';
  END IF;
  IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'business_manager') <> 'business_manager_audit_owner' THEN
    RAISE EXCEPTION 'schema business_manager is not owned by business_manager_audit_owner';
  END IF;
  IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'business_manager.audit_logs'::regclass) <> 'business_manager_audit_owner'
     OR (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'business_manager.audit_logs_id_seq'::regclass) <> 'business_manager_audit_owner' THEN
    RAISE EXCEPTION 'audit_logs or its sequence is not owned by business_manager_audit_owner';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'business_manager' AND p.proname LIKE 'audit\_logs\_%'
                AND pg_get_userbyid(p.proowner) <> 'business_manager_audit_owner') THEN
    RAISE EXCEPTION 'an audit_logs_* function is not owned by business_manager_audit_owner';
  END IF;
  IF NOT (has_table_privilege('business_manager', 'business_manager.audit_logs', 'SELECT')
          AND has_table_privilege('business_manager', 'business_manager.audit_logs', 'INSERT')
          AND has_table_privilege('business_manager', 'business_manager.audit_logs', 'DELETE')
          AND has_sequence_privilege('business_manager', 'business_manager.audit_logs_id_seq', 'USAGE')
          AND has_schema_privilege('business_manager', 'business_manager', 'CREATE')) THEN
    RAISE EXCEPTION 'business_manager is missing a privilege it needs (SELECT/INSERT/DELETE, sequence USAGE, schema CREATE)';
  END IF;
  IF has_table_privilege('business_manager', 'business_manager.audit_logs', 'UPDATE')
     OR has_table_privilege('business_manager', 'business_manager.audit_logs', 'TRUNCATE')
     OR has_table_privilege('business_manager', 'business_manager.audit_logs', 'TRIGGER') THEN
    RAISE EXCEPTION 'business_manager still holds UPDATE, TRUNCATE or TRIGGER on audit_logs';
  END IF;
  IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid = 'business_manager.audit_logs'::regclass) THEN
    RAISE EXCEPTION 'audit_logs lost ENABLE/FORCE ROW LEVEL SECURITY';
  END IF;
  IF (SELECT count(*) FROM pg_trigger WHERE tgrelid = 'business_manager.audit_logs'::regclass AND NOT tgisinternal AND tgenabled = 'O') < 4 THEN
    RAISE EXCEPTION 'audit_logs is missing an enabled trigger (expected seal + no_update + no_delete + no_truncate)';
  END IF;
  RAISE NOTICE 'OK  business_manager: audit_logs, its functions and schema business_manager are owned by business_manager_audit_owner';
END $$;

COMMIT;
