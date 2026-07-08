-- rls-template.sql — the RLS shape EVERY org-scoped table must have.
-- Source of truth: db-unification/specs/data-standards.md §3. GUC standard:
-- ADR-0042 (app.org_id). FORCE RLS is non-negotiable — ENABLE-only is a harness
-- finding. Replace <t> with the table name.

-- ── Standard org-scoped table ────────────────────────────────────────────────
ALTER TABLE <t> ADD COLUMN IF NOT EXISTS org_id uuid NOT NULL
    DEFAULT NULLIF(current_setting('app.org_id', true), '')::uuid;
CREATE INDEX IF NOT EXISTS <t>_org_idx ON <t> (org_id);

ALTER TABLE <t> ENABLE ROW LEVEL SECURITY;
ALTER TABLE <t> FORCE ROW LEVEL SECURITY;      -- non-negotiable

CREATE POLICY org_isolation ON <t>
    USING      (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid)
    WITH CHECK (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid);

-- ── Append-only table (audit/event) — additionally ───────────────────────────
-- Per-command policies + a universal-false UPDATE/DELETE, then REVOKE the DML.
-- PM's baseline/snapshot tables are the reference (npol=4).
--
--   CREATE POLICY <t>_insert ON <t> FOR INSERT
--       WITH CHECK (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid);
--   CREATE POLICY <t>_select ON <t> FOR SELECT
--       USING (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid);
--   CREATE POLICY <t>_no_update ON <t> FOR UPDATE USING (false);
--   CREATE POLICY <t>_no_delete ON <t> FOR DELETE USING (false);
--   REVOKE UPDATE, DELETE ON <t> FROM <app>;   -- and <app>_app if you have one
--
-- Declare append-only tables in db/conformance-manifest.json so the harness
-- knows the missing org_isolation policy is intentional (§6).

-- ── Worker/outbox tables that must scan cross-org ─────────────────────────────
-- NO RLS is acceptable ONLY with (a) org_id per row, (b) access confined to
-- SECURITY DEFINER claim functions or a dedicated worker role, and (c) a
-- conformance-manifest entry saying so. Silent exemptions are what the harness
-- exists to catch. Prefer @jaupole/ecosystem-db's /outbox helper for new code.

-- Per-request context (set in your tx helper, NOT here):
--   SET LOCAL app.org_id  = '<the active org uuid>';
--   SET LOCAL app.user_id = '<the acting principal>';
