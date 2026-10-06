-- Audit owner separation — Proposal Forge (database proposal_forge).
--
-- WHY. The app's login role `proposal_forge` owned its own audit table, the
-- functions behind the append-only triggers, and (as database owner) schema
-- public. Whoever holds the app's database password could therefore
--   ALTER TABLE audit_log DISABLE TRIGGER …      (switch the protection off)
--   CREATE OR REPLACE FUNCTION audit_log_block_mutate() …   (hollow it out)
--   DROP TABLE audit_log                          (schema owner may drop any table)
-- and rewrite history, recomputing the hash chain as it went. The copy in
-- Control and the off-site anchor would still expose it, but the local
-- protection was only as strong as the app's own restraint.
--
-- WHAT. The audit table, its sequence, its functions and schema public move to
-- `proposal_forge_audit_owner`: NOLOGIN, no password, no members. Nobody can
-- connect as it or SET ROLE to it; only the in-pod superuser can act on those
-- objects. The app keeps exactly what it needs: SELECT, INSERT, and DELETE
-- (retention only — still gated by the purge flag, the three-year policy and
-- the trigger), plus CREATE in the schema so its migrations keep working.
--
-- CONSEQUENCE. A future migration that alters audit_log or its functions
-- cannot be applied by the app's migration Job any more ("must be owner").
-- Apply that one migration by hand as the in-pod superuser — see
-- docs/03-runbooks/audit-owner-separation.md. The app repo has a test that
-- fails the build when a new migration touches the audit table.
--
-- Run as the in-pod superuser:  psql -U postgres -d proposal_forge -f <this>
-- Idempotent: safe to re-run; the last block re-checks the posture each time.

\set ON_ERROR_STOP on
BEGIN;

-- Refuse unless the app's last audit migration is in. After this script the
-- app's migration Job can no longer alter these objects, so it must not be
-- run ahead of a migration that still needs to.
DO $$
BEGIN
  IF to_regprocedure('public.audit_log_guard_delete()') IS NULL THEN
    RAISE EXCEPTION 'deploy Proposal Forge with migration 20261006190000_audit_log_delete_guard first';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'proposal_forge_audit_owner') THEN
    CREATE ROLE proposal_forge_audit_owner
      NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION;
  END IF;
END $$;

-- The schema first: its owner may drop any object in it, whoever owns the object.
ALTER SCHEMA public OWNER TO proposal_forge_audit_owner;
GRANT USAGE, CREATE ON SCHEMA public TO proposal_forge;

-- The table. Its indexes and the sequence owned by audit_log.seq move with it.
ALTER TABLE public.audit_log OWNER TO proposal_forge_audit_owner;

-- Every audit_log_* function: the seal, the guards, the hash and the verifier.
-- Whoever owns a trigger's function can hollow the trigger out.
DO $$
DECLARE
  f regprocedure;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname LIKE 'audit\_log\_%'
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO proposal_forge_audit_owner', f);
  END LOOP;
END $$;

-- What the app keeps. No UPDATE, TRUNCATE, TRIGGER or REFERENCES.
REVOKE ALL ON public.audit_log FROM PUBLIC, proposal_forge;
GRANT SELECT, INSERT, DELETE ON public.audit_log TO proposal_forge;
REVOKE ALL ON SEQUENCE public.audit_log_seq_seq FROM PUBLIC, proposal_forge;
GRANT USAGE ON SEQUENCE public.audit_log_seq_seq TO proposal_forge;

-- ─── Posture check ───────────────────────────────────────────────────────────
DO $$
DECLARE
  r record;
BEGIN
  SELECT rolcanlogin, rolsuper, rolbypassrls, rolcreaterole INTO r
    FROM pg_roles WHERE rolname = 'proposal_forge_audit_owner';
  IF r.rolcanlogin OR r.rolsuper OR r.rolbypassrls OR r.rolcreaterole THEN
    RAISE EXCEPTION 'proposal_forge_audit_owner must be NOLOGIN, non-superuser, NOBYPASSRLS, NOCREATEROLE';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles o ON o.oid = m.roleid
              WHERE o.rolname = 'proposal_forge_audit_owner') THEN
    RAISE EXCEPTION 'proposal_forge_audit_owner has members: someone could SET ROLE to it';
  END IF;
  IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'public') <> 'proposal_forge_audit_owner' THEN
    RAISE EXCEPTION 'schema public is not owned by proposal_forge_audit_owner';
  END IF;
  IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.audit_log'::regclass) <> 'proposal_forge_audit_owner'
     OR (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.audit_log_seq_seq'::regclass) <> 'proposal_forge_audit_owner' THEN
    RAISE EXCEPTION 'audit_log or its sequence is not owned by proposal_forge_audit_owner';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public' AND p.proname LIKE 'audit\_log\_%'
                AND pg_get_userbyid(p.proowner) <> 'proposal_forge_audit_owner') THEN
    RAISE EXCEPTION 'an audit_log_* function is not owned by proposal_forge_audit_owner';
  END IF;
  IF NOT (has_table_privilege('proposal_forge', 'public.audit_log', 'SELECT')
          AND has_table_privilege('proposal_forge', 'public.audit_log', 'INSERT')
          AND has_table_privilege('proposal_forge', 'public.audit_log', 'DELETE')
          AND has_sequence_privilege('proposal_forge', 'public.audit_log_seq_seq', 'USAGE')
          AND has_schema_privilege('proposal_forge', 'public', 'CREATE')) THEN
    RAISE EXCEPTION 'proposal_forge is missing a privilege it needs (SELECT/INSERT/DELETE, sequence USAGE, schema CREATE)';
  END IF;
  IF has_table_privilege('proposal_forge', 'public.audit_log', 'UPDATE')
     OR has_table_privilege('proposal_forge', 'public.audit_log', 'TRUNCATE')
     OR has_table_privilege('proposal_forge', 'public.audit_log', 'TRIGGER') THEN
    RAISE EXCEPTION 'proposal_forge still holds UPDATE, TRUNCATE or TRIGGER on audit_log';
  END IF;
  IF NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid = 'public.audit_log'::regclass) THEN
    RAISE EXCEPTION 'audit_log lost ENABLE/FORCE ROW LEVEL SECURITY';
  END IF;
  IF (SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.audit_log'::regclass AND NOT tgisinternal AND tgenabled = 'O') < 4 THEN
    RAISE EXCEPTION 'audit_log is missing an enabled trigger (expected seal + no_update + no_delete + no_truncate)';
  END IF;
  RAISE NOTICE 'OK  proposal_forge: audit_log, its functions and schema public are owned by proposal_forge_audit_owner';
END $$;

COMMIT;
