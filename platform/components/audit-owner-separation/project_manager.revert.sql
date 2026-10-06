-- Audit owner separation — LEND the audit objects back to the app (project_manager).
--
-- For one purpose: shipping an app migration that has to alter the audit
-- table or its functions. The app's migration Job cannot do that while
-- `project_manager_audit_owner` owns them. Run this, deploy the app, then run project_manager.sql again to
-- take ownership back (it re-checks the posture). While lent, the app's own
-- credentials can again switch the protection off — keep the window short.
-- See docs/03-runbooks/audit-owner-separation.md.
--
-- Run as the in-pod superuser:  psql -U postgres -d project_manager -f <this>

\set ON_ERROR_STOP on
BEGIN;

ALTER SCHEMA audit OWNER TO project_manager;

DO $$
DECLARE
  t regclass;
BEGIN
  FOR t IN
    SELECT c.oid::regclass FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'audit' AND c.relkind = 'r'
  LOOP
    EXECUTE format('ALTER TABLE %s OWNER TO project_manager', t);
  END LOOP;
END $$;

DO $$
DECLARE
  f regprocedure;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'audit'
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO project_manager', f);
  END LOOP;
END $$;

DO $$ BEGIN RAISE NOTICE 'LENT  project_manager owns schema audit again; re-run project_manager.sql after the deploy'; END $$;

COMMIT;
