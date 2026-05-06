-- Phase 10.1.3 — Row Level Security policies on every project_tracker table.
--
-- Pattern (one block per table; rationale appears once here):
--
--   1. ENABLE ROW LEVEL SECURITY on the table.
--   2. CREATE POLICY tenant_isolation ON the table
--        FOR ALL TO project_tracker_app
--        USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
--        WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);
--
-- The runtime app role (project-tracker-readwrite, dynamic-cred from
-- OpenBao) inherits project_tracker_app and so falls under this policy.
-- The PT backend sets `app.tenant_id` once per request from the BFF-
-- injected identity header (the `tenant_id` claim flows from Keycloak's
-- realm assignment per the audit doc).
--
-- The `, true` second argument to current_setting tells Postgres to
-- return NULL when the GUC is unset. Comparing `tenant_id = NULL` is
-- always NULL (not TRUE), and a NULL row-filter excludes the row →
-- queries that forget to set `app.tenant_id` return zero rows. This
-- is fail-closed by design: if the BFF-injected identity middleware
-- ever fails to wire `app.tenant_id` for a request, the request sees
-- an empty database rather than another tenant's data.
--
-- WITH CHECK enforces the same constraint on writes — an INSERT/UPDATE
-- that tries to land a row with a different tenant_id is rejected.
--
-- Migrations and bulk imports bypass RLS via a per-session
-- `SET LOCAL row_security = off`. The migrate role granted to
-- project-tracker-migrate inherits project_tracker_app (so it falls
-- under the policy by default) but the per-session toggle disables
-- enforcement during transactional imports — see 003-import.sh.

-- ─── people ─────────────────────────────────────────────────────────
ALTER TABLE project_tracker.people ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON project_tracker.people
    FOR ALL TO project_tracker_app
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- ─── projects ───────────────────────────────────────────────────────
ALTER TABLE project_tracker.projects ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON project_tracker.projects
    FOR ALL TO project_tracker_app
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- ─── project_budget_lines ───────────────────────────────────────────
ALTER TABLE project_tracker.project_budget_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON project_tracker.project_budget_lines
    FOR ALL TO project_tracker_app
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- ─── tasks ──────────────────────────────────────────────────────────
ALTER TABLE project_tracker.tasks ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON project_tracker.tasks
    FOR ALL TO project_tracker_app
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- ─── pursuits ───────────────────────────────────────────────────────
ALTER TABLE project_tracker.pursuits ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON project_tracker.pursuits
    FOR ALL TO project_tracker_app
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- ─── comms_log ──────────────────────────────────────────────────────
ALTER TABLE project_tracker.comms_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON project_tracker.comms_log
    FOR ALL TO project_tracker_app
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- ─── opp_watch_tracks ───────────────────────────────────────────────
ALTER TABLE project_tracker.opp_watch_tracks ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON project_tracker.opp_watch_tracks
    FOR ALL TO project_tracker_app
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- ─── opp_watch_queries ──────────────────────────────────────────────
ALTER TABLE project_tracker.opp_watch_queries ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON project_tracker.opp_watch_queries
    FOR ALL TO project_tracker_app
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- ─── opp_watch_results ──────────────────────────────────────────────
ALTER TABLE project_tracker.opp_watch_results ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON project_tracker.opp_watch_results
    FOR ALL TO project_tracker_app
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- ─── bl_requests ────────────────────────────────────────────────────
ALTER TABLE project_tracker.bl_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON project_tracker.bl_requests
    FOR ALL TO project_tracker_app
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- ─── audit_logs ─────────────────────────────────────────────────────
ALTER TABLE project_tracker.audit_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON project_tracker.audit_logs
    FOR ALL TO project_tracker_app
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- ─── bl_request_contacts ────────────────────────────────────────────
ALTER TABLE project_tracker.bl_request_contacts ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON project_tracker.bl_request_contacts
    FOR ALL TO project_tracker_app
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- ─── bl_submissions ─────────────────────────────────────────────────
ALTER TABLE project_tracker.bl_submissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON project_tracker.bl_submissions
    FOR ALL TO project_tracker_app
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- ─── bl_submission_lines ────────────────────────────────────────────
ALTER TABLE project_tracker.bl_submission_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON project_tracker.bl_submission_lines
    FOR ALL TO project_tracker_app
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);
