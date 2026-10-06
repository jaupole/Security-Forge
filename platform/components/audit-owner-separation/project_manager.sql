-- Audit owner separation — Project Manager (database project_manager).
--
-- WHY. Project Manager's queries run as `project_manager_app`, which may only
-- INSERT and SELECT audit rows. But the role the app LOGS IN as,
-- `project_manager`, owned schema audit and everything in it — the table, the
-- tamper flag, and the SECURITY DEFINER functions that hash, verify, export
-- and purge. Whoever holds the app's database password could therefore edit or
-- delete audit rows directly, or replace audit.set_full_hash() with something
-- else, and recompute the hash chain as it went. The copy in Control and the
-- off-site anchor would still expose it, but the local protection was only as
-- strong as the app's own restraint.
--
-- WHAT. Schema audit and every table, sequence and function in it move to
-- `project_manager_audit_owner`: NOLOGIN, no password, no members. Nobody can
-- connect as it or SET ROLE to it; only the in-pod superuser can act on those
-- objects. Nothing changes for `project_manager_app`: its grants are kept as
-- they are. The SECURITY DEFINER functions now run as the new owner, which
-- owns the table and is therefore not bound by its (non-FORCE) row security —
-- the same footing they had before, without needing a BYPASSRLS role.
--
-- CONSEQUENCE. A future migration that alters anything in schema audit cannot
-- be applied by the app's migration Job any more ("must be owner"). Apply that
-- one migration by hand as the in-pod superuser — see
-- docs/03-runbooks/audit-owner-separation.md. The app repo has a test that
-- fails the build when a new migration touches the audit schema. Setting
-- audit.tamper_flag is likewise a superuser action now.
--
-- Run as the in-pod superuser:  psql -U postgres -d project_manager -f <this>
-- Idempotent: safe to re-run; the last block re-checks the posture each time.

\set ON_ERROR_STOP on
BEGIN;

-- Refuse unless the app's last audit migration is in. After this script the
-- app's migration Job can no longer alter these objects, so it must not be
-- run ahead of a migration that still needs to.
DO $$
BEGIN
  IF to_regprocedure('audit.purge_expired()') IS NULL THEN
    RAISE EXCEPTION 'deploy Project Manager with migration 035_audit_retention first';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'project_manager_audit_owner') THEN
    CREATE ROLE project_manager_audit_owner
      NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION;
  END IF;
END $$;

-- Refuse on a database this script does not fit. The SECURITY DEFINER functions
-- rely on the table's OWNER being exempt from its row security; under FORCE
-- they would be bound by the "never update, never delete" policies and every
-- audit write would stop.
DO $$
BEGIN
  IF (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'audit.event'::regclass) THEN
    RAISE EXCEPTION 'audit.event has FORCE ROW LEVEL SECURITY; this separation would break audit.set_full_hash()';
  END IF;
END $$;

-- The schema first: its owner may drop any object in it, whoever owns the object.
ALTER SCHEMA audit OWNER TO project_manager_audit_owner;

-- Every table in the schema (sequences owned by their columns move with them),
-- then every function. Existing grants to project_manager_app are kept.
DO $$
DECLARE
  t regclass;
  f regprocedure;
BEGIN
  FOR t IN
    SELECT c.oid::regclass FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'audit' AND c.relkind = 'r'
  LOOP
    EXECUTE format('ALTER TABLE %s OWNER TO project_manager_audit_owner', t);
    -- The old owner keeps nothing of its own on the table.
    EXECUTE format('REVOKE ALL ON %s FROM project_manager', t);
  END LOOP;
  FOR f IN
    SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'audit'
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO project_manager_audit_owner', f);
  END LOOP;
END $$;

-- ─── Posture check ───────────────────────────────────────────────────────────
DO $$
DECLARE
  r record;
BEGIN
  SELECT rolcanlogin, rolsuper, rolbypassrls, rolcreaterole INTO r
    FROM pg_roles WHERE rolname = 'project_manager_audit_owner';
  IF r.rolcanlogin OR r.rolsuper OR r.rolbypassrls OR r.rolcreaterole THEN
    RAISE EXCEPTION 'project_manager_audit_owner must be NOLOGIN, non-superuser, NOBYPASSRLS, NOCREATEROLE';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles o ON o.oid = m.roleid
              WHERE o.rolname = 'project_manager_audit_owner') THEN
    RAISE EXCEPTION 'project_manager_audit_owner has members: someone could SET ROLE to it';
  END IF;
  IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'audit') <> 'project_manager_audit_owner' THEN
    RAISE EXCEPTION 'schema audit is not owned by project_manager_audit_owner';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'audit' AND c.relkind IN ('r', 'S')
                AND pg_get_userbyid(c.relowner) <> 'project_manager_audit_owner')
     OR EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'audit' AND pg_get_userbyid(p.proowner) <> 'project_manager_audit_owner') THEN
    RAISE EXCEPTION 'something in schema audit is not owned by project_manager_audit_owner';
  END IF;
  IF NOT (has_table_privilege('project_manager_app', 'audit.event', 'SELECT')
          AND has_table_privilege('project_manager_app', 'audit.event', 'INSERT')
          AND has_sequence_privilege('project_manager_app', 'audit.event_id_seq', 'USAGE')
          AND has_table_privilege('project_manager_app', 'audit.tamper_flag', 'SELECT')
          AND has_schema_privilege('project_manager_app', 'audit', 'USAGE')
          AND has_function_privilege('project_manager_app', 'audit.set_full_hash(bigint)', 'EXECUTE')) THEN
    RAISE EXCEPTION 'project_manager_app lost a privilege it needs on schema audit';
  END IF;
  IF has_table_privilege('project_manager_app', 'audit.event', 'UPDATE')
     OR has_table_privilege('project_manager_app', 'audit.event', 'DELETE')
     OR has_table_privilege('project_manager', 'audit.event', 'UPDATE')
     OR has_table_privilege('project_manager', 'audit.event', 'DELETE')
     OR has_table_privilege('project_manager', 'audit.tamper_flag', 'UPDATE') THEN
    RAISE EXCEPTION 'an app role can still UPDATE or DELETE in schema audit';
  END IF;
  RAISE NOTICE 'OK  project_manager: schema audit and everything in it is owned by project_manager_audit_owner';
END $$;

COMMIT;
