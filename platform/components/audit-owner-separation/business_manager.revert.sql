-- Audit owner separation — LEND the audit objects back to the app (business_manager).
--
-- For one purpose: shipping an app migration that has to alter the audit
-- table or its functions. The app's migration Job cannot do that while
-- `business_manager_audit_owner` owns them. Run this, deploy the app, then run business_manager.sql again to
-- take ownership back (it re-checks the posture). While lent, the app's own
-- credentials can again switch the protection off — keep the window short.
-- See docs/03-runbooks/audit-owner-separation.md.
--
-- Run as the in-pod superuser:  psql -U postgres -d business_manager -f <this>

\set ON_ERROR_STOP on
BEGIN;

ALTER SCHEMA business_manager OWNER TO business_manager;
ALTER TABLE business_manager.audit_logs OWNER TO business_manager;

DO $$
DECLARE
  f regprocedure;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'business_manager' AND p.proname LIKE 'audit\_logs\_%'
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO business_manager', f);
  END LOOP;
END $$;

DO $$ BEGIN RAISE NOTICE 'LENT  business_manager owns audit_logs again; re-run business_manager.sql after the deploy'; END $$;

COMMIT;
