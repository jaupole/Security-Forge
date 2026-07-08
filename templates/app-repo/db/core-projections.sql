-- core-projections.sql — read-only local projections of Ecosystem Control's
-- canonical directories (ADR-0041). Control OWNS these records; the app keeps a
-- local copy synced by polling Control's GET /api/v1/system/core-export (see
-- core-sync.stub.ts). By convention ONLY the sync module writes these tables;
-- app modules READ them (pickers, directory lookups, audit-name rendering).
--
-- Upserts are version-guarded: a row updates only when the incoming `version`
-- is strictly newer, so out-of-order pages can never regress a record.
-- Projection rows are soft-deleted (active=false), never hard-deleted, so the
-- app may FK against them safely.
--
-- Replace <app>_app with your app's runtime role (the login role <app> if you
-- have no SET-ROLE split). GUC is app.org_id (ADR-0042).

BEGIN;

-- ── People ───────────────────────────────────────────────────────────────────
CREATE TABLE core_people (
  id           UUID PRIMARY KEY,        -- Control's canonical person id
  org_id       UUID NOT NULL,
  kc_sub       UUID,                     -- Keycloak sub, when the person has an account
  display_name TEXT NOT NULL,
  email_hmac   BYTEA,                    -- Control's keyed HMAC; app NEVER stores plaintext email
  has_email    BOOLEAN NOT NULL DEFAULT false,
  phone        TEXT,
  active       BOOLEAN NOT NULL,
  version      BIGINT NOT NULL,          -- upsert guard
  synced_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX core_people_org_idx ON core_people (org_id);
CREATE UNIQUE INDEX core_people_org_kc_sub_uidx ON core_people (org_id, kc_sub) WHERE kc_sub IS NOT NULL;
ALTER TABLE core_people ENABLE ROW LEVEL SECURITY;
ALTER TABLE core_people FORCE ROW LEVEL SECURITY;
CREATE POLICY core_people_org_isolation ON core_people
  USING      (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid)
  WITH CHECK (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid);
GRANT SELECT, INSERT, UPDATE ON core_people TO <app>_app;   -- no DELETE: soft-delete only

-- ── Clients ──────────────────────────────────────────────────────────────────
CREATE TABLE core_clients (
  id           UUID PRIMARY KEY,
  org_id       UUID NOT NULL,
  display_name TEXT NOT NULL,
  active       BOOLEAN NOT NULL,
  version      BIGINT NOT NULL,
  synced_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX core_clients_org_idx ON core_clients (org_id);
ALTER TABLE core_clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE core_clients FORCE ROW LEVEL SECURITY;
CREATE POLICY core_clients_org_isolation ON core_clients
  USING      (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid)
  WITH CHECK (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid);
GRANT SELECT, INSERT, UPDATE ON core_clients TO <app>_app;

-- ── Engagements (the golden thread) ──────────────────────────────────────────
CREATE TABLE core_engagements (
  id           UUID PRIMARY KEY,
  org_id       UUID NOT NULL,
  title        TEXT NOT NULL,
  stage        TEXT NOT NULL,
  client_id    UUID,                     -- FK-able to core_clients.id (same org)
  active       BOOLEAN NOT NULL,
  version      BIGINT NOT NULL,
  synced_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX core_engagements_org_idx ON core_engagements (org_id);
ALTER TABLE core_engagements ENABLE ROW LEVEL SECURITY;
ALTER TABLE core_engagements FORCE ROW LEVEL SECURITY;
CREATE POLICY core_engagements_org_isolation ON core_engagements
  USING      (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid)
  WITH CHECK (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid);
GRANT SELECT, INSERT, UPDATE ON core_engagements TO <app>_app;

-- ── Sync cursor: app-global high-water mark, one row per entity type ─────────
-- NO RLS — infrastructure state, not tenant data (a single cursor spans every
-- org in the export stream), like schema_migrations. Declare it in the
-- conformance manifest as an intentional non-org-scoped table.
CREATE TABLE core_sync_cursor (
  entity_type TEXT PRIMARY KEY,          -- 'person' | 'client' | 'engagement'
  cursor      BIGINT NOT NULL DEFAULT 0, -- Control's syncSeq high-water mark
  synced_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON core_sync_cursor TO <app>_app;

-- Link columns: on your OWN domain tables, add nullable person_id/client_id/
-- engagement_id and stamp them when a picker chooses a directory entity. Keep
-- any free-text label nullable for placeholder entities not yet in the directory.
--   ALTER TABLE <your_table> ADD COLUMN person_id UUID;      -- REFERENCES core_people(id) logically

COMMIT;
