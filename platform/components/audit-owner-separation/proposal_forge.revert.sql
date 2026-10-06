-- Audit owner separation — LEND the audit objects back to the app (proposal_forge).
--
-- For one purpose: shipping an app migration that has to alter the audit
-- table or its functions. The app's migration Job cannot do that while
-- `proposal_forge_audit_owner` owns them. Run this, deploy the app, then run proposal_forge.sql again to
-- take ownership back (it re-checks the posture). While lent, the app's own
-- credentials can again switch the protection off — keep the window short.
-- See docs/03-runbooks/audit-owner-separation.md.
--
-- Run as the in-pod superuser:  psql -U postgres -d proposal_forge -f <this>

\set ON_ERROR_STOP on
BEGIN;

ALTER SCHEMA public OWNER TO pg_database_owner;
ALTER TABLE public.audit_log OWNER TO proposal_forge;

DO $$
DECLARE
  f regprocedure;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname LIKE 'audit\_log\_%'
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO proposal_forge', f);
  END LOOP;
END $$;

DO $$ BEGIN RAISE NOTICE 'LENT  proposal_forge owns audit_log again; re-run proposal_forge.sql after the deploy'; END $$;

COMMIT;
