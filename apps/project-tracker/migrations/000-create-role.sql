-- Phase 10.1.3 — base Postgres role for the project_tracker schema.
--
-- The runtime + migration roles minted dynamically by OpenBao
-- (project-tracker-readwrite / project-tracker-migrate) inherit this
-- base role to pick up the FOR-ALL-TO grants installed by RLS policies
-- in 002-rls-policies.sql.
--
-- This file is run by provision-db-and-bao.sh (the
-- DO/IF NOT EXISTS shape, not this raw form). It is also kept here as
-- the canonical SQL for the base role definition so future operators
-- can find it via the migrations/ directory.
--
-- Idempotent. Safe to re-run.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'project_tracker_app') THEN
        CREATE ROLE project_tracker_app NOLOGIN;
    END IF;
END$$;

-- Let the OpenBao-connecting `app` user grant membership in this role
-- during dynamic-cred mint (Postgres 16+ requires ADMIN OPTION).
GRANT project_tracker_app TO app WITH ADMIN OPTION;

-- Schema-level grants. The schema itself was created by the CNPG cluster
-- bootstrap (infrastructure/cloudnativepg/clusters/app-db.yaml's
-- postInitApplicationSQL); we only need to widen access to the role.
GRANT USAGE  ON SCHEMA project_tracker TO project_tracker_app;
GRANT CREATE ON SCHEMA project_tracker TO project_tracker_app;
