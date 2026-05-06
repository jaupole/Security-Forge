-- Phase 10.1.3 — Project Tracker baseline schema for secforge-app-db.
--
-- This file is a verbatim copy of the Prisma-generated migration in
-- the PT repo at:
--     prisma/migrations/20260505234638_10_1_3_secforge_integration/migration.sql
--
-- DO NOT hand-edit this file in the platform repo. When PT's Prisma
-- schema changes:
--     1. PT operator runs `prisma migrate dev --name <change>` and
--        commits the new migration to the PT repo
--     2. The new migration.sql is promoted into this directory as
--        00N-<change>.sql (next sequential number)
--     3. apply.sh's psql invocation order picks it up (lexicographic)
-- The README documents this convention.
--
-- The migration creates 14 tables under the `project_tracker` schema
-- with tenant_id UUID NOT NULL on every row. RLS policies live in
-- 002-rls-policies.sql so the policy logic is reviewable in isolation
-- from the table shape.

-- CreateSchema
CREATE SCHEMA IF NOT EXISTS "project_tracker";

-- CreateTable
CREATE TABLE "project_tracker"."people" (
    "id" BIGSERIAL NOT NULL,
    "tenant_id" UUID NOT NULL,
    "name" TEXT NOT NULL,
    "email" TEXT,
    "labor_category" TEXT,
    "bill_rate_cents" INTEGER,
    "cost_rate_cents" INTEGER,
    "role_on_team" TEXT,
    "active" BOOLEAN NOT NULL DEFAULT true,
    "notes" TEXT,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,
    "deleted_at" TIMESTAMPTZ(6),

    CONSTRAINT "people_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "project_tracker"."projects" (
    "id" BIGSERIAL NOT NULL,
    "tenant_id" UUID NOT NULL,
    "name" TEXT NOT NULL,
    "client" TEXT,
    "stage" TEXT NOT NULL DEFAULT 'not_started',
    "pm_id" BIGINT,
    "start_date" DATE,
    "end_date" DATE,
    "budget_hours" DECIMAL(10,2),
    "actual_hours" DECIMAL(10,2),
    "notes" TEXT,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,
    "deleted_at" TIMESTAMPTZ(6),

    CONSTRAINT "projects_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "project_tracker"."project_budget_lines" (
    "id" BIGSERIAL NOT NULL,
    "tenant_id" UUID NOT NULL,
    "project_id" BIGINT NOT NULL,
    "sort_index" INTEGER NOT NULL DEFAULT 0,
    "phase" TEXT,
    "role" TEXT NOT NULL,
    "hours" DECIMAL(10,2) NOT NULL,
    "rate_cents" INTEGER NOT NULL,
    "extended_cost_cents" BIGINT NOT NULL,
    "notes" TEXT,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "project_budget_lines_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "project_tracker"."tasks" (
    "id" BIGSERIAL NOT NULL,
    "tenant_id" UUID NOT NULL,
    "title" TEXT NOT NULL,
    "description" TEXT,
    "parent_type" TEXT NOT NULL,
    "parent_id" BIGINT NOT NULL,
    "owner_id" BIGINT,
    "comms_log_id" BIGINT,
    "due_date" TIMESTAMPTZ(6),
    "due_cob" BOOLEAN NOT NULL DEFAULT true,
    "status" TEXT NOT NULL DEFAULT 'not_started',
    "priority" TEXT NOT NULL DEFAULT 'normal',
    "completed_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,
    "deleted_at" TIMESTAMPTZ(6),

    CONSTRAINT "tasks_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "project_tracker"."pursuits" (
    "id" BIGSERIAL NOT NULL,
    "tenant_id" UUID NOT NULL,
    "code" TEXT,
    "name" TEXT NOT NULL,
    "agency" TEXT,
    "solicitation_number" TEXT,
    "stage" TEXT NOT NULL DEFAULT 'identified',
    "probability_pct" INTEGER,
    "due_date" DATE,
    "owner_id" BIGINT,
    "source" TEXT,
    "external_url" TEXT,
    "estimated_value" DECIMAL(14,2),
    "notes" TEXT,
    "closed_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,
    "deleted_at" TIMESTAMPTZ(6),

    CONSTRAINT "pursuits_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "project_tracker"."comms_log" (
    "id" BIGSERIAL NOT NULL,
    "tenant_id" UUID NOT NULL,
    "parent_type" TEXT,
    "parent_id" BIGINT,
    "direction" TEXT NOT NULL,
    "from_name" TEXT,
    "from_email" TEXT,
    "subject" TEXT,
    "summary" TEXT,
    "action_required" BOOLEAN NOT NULL DEFAULT false,
    "due_date" TIMESTAMPTZ(6),
    "due_cob" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,
    "deleted_at" TIMESTAMPTZ(6),

    CONSTRAINT "comms_log_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "project_tracker"."opp_watch_tracks" (
    "id" BIGSERIAL NOT NULL,
    "tenant_id" UUID NOT NULL,
    "slug" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "color" TEXT NOT NULL DEFAULT 'violet',
    "sort_order" INTEGER NOT NULL DEFAULT 0,
    "active" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,
    "deleted_at" TIMESTAMPTZ(6),

    CONSTRAINT "opp_watch_tracks_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "project_tracker"."opp_watch_queries" (
    "id" BIGSERIAL NOT NULL,
    "tenant_id" UUID NOT NULL,
    "name" TEXT NOT NULL,
    "track_id" BIGINT NOT NULL,
    "criteria" JSONB NOT NULL,
    "schedule_cron" TEXT NOT NULL DEFAULT '0 7 * * *',
    "active" BOOLEAN NOT NULL DEFAULT true,
    "last_run_at" TIMESTAMPTZ(6),
    "last_hit_count" INTEGER,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "opp_watch_queries_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "project_tracker"."opp_watch_results" (
    "id" BIGSERIAL NOT NULL,
    "tenant_id" UUID NOT NULL,
    "query_id" BIGINT NOT NULL,
    "sam_notice_id" TEXT NOT NULL,
    "title" TEXT NOT NULL,
    "agency" TEXT,
    "posted_date" DATE,
    "due_date" DATE,
    "link" TEXT,
    "notice_type" TEXT,
    "naics_code" TEXT,
    "psc_code" TEXT,
    "set_aside" TEXT,
    "pop_state" TEXT,
    "pop_city" TEXT,
    "contact_name" TEXT,
    "contact_email" TEXT,
    "contact_phone" TEXT,
    "description" TEXT,
    "award_amount_cents" BIGINT,
    "awardee_name" TEXT,
    "resource_links_count" INTEGER NOT NULL DEFAULT 0,
    "status" TEXT NOT NULL DEFAULT 'new',
    "promoted_pursuit_id" BIGINT,
    "snapshot" JSONB,
    "first_seen_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "last_seen_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "opp_watch_results_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "project_tracker"."bl_requests" (
    "id" BIGSERIAL NOT NULL,
    "tenant_id" UUID NOT NULL,
    "code" TEXT,
    "name" TEXT NOT NULL,
    "request_type" TEXT NOT NULL,
    "request_type_other" TEXT,
    "contract_docs_url" TEXT,
    "office" TEXT,
    "client" TEXT,
    "primary_pm_id" BIGINT,
    "responsible_id" BIGINT,
    "received_at" TIMESTAMPTZ(6),
    "due_date" DATE,
    "status" TEXT NOT NULL DEFAULT 'received',
    "notes" TEXT,
    "project_id" BIGINT,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,
    "deleted_at" TIMESTAMPTZ(6),

    CONSTRAINT "bl_requests_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "project_tracker"."audit_logs" (
    "id" BIGSERIAL NOT NULL,
    "tenant_id" UUID NOT NULL,
    "entity_type" TEXT NOT NULL,
    "entity_id" BIGINT NOT NULL,
    "action" TEXT NOT NULL,
    "changed_by_id" BIGINT,
    "summary" TEXT,
    "data" JSONB,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "project_tracker"."bl_request_contacts" (
    "tenant_id" UUID NOT NULL,
    "bl_request_id" BIGINT NOT NULL,
    "person_id" BIGINT NOT NULL,
    "role_on_request" TEXT,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "bl_request_contacts_pkey" PRIMARY KEY ("bl_request_id","person_id")
);

-- CreateTable
CREATE TABLE "project_tracker"."bl_submissions" (
    "id" BIGSERIAL NOT NULL,
    "tenant_id" UUID NOT NULL,
    "bl_request_id" BIGINT NOT NULL,
    "revision" INTEGER NOT NULL,
    "submitted_at" TIMESTAMPTZ(6),
    "total_hours" DECIMAL(12,2),
    "total_cost_cents" BIGINT,
    "summary" TEXT,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,
    "deleted_at" TIMESTAMPTZ(6),

    CONSTRAINT "bl_submissions_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "project_tracker"."bl_submission_lines" (
    "id" BIGSERIAL NOT NULL,
    "tenant_id" UUID NOT NULL,
    "bl_submission_id" BIGINT NOT NULL,
    "sort_index" INTEGER NOT NULL DEFAULT 0,
    "phase" TEXT,
    "role" TEXT NOT NULL,
    "hours" DECIMAL(10,2) NOT NULL,
    "rate_cents" INTEGER NOT NULL,
    "extended_cost_cents" BIGINT NOT NULL,
    "notes" TEXT,

    CONSTRAINT "bl_submission_lines_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "people_active_idx" ON "project_tracker"."people"("active");

-- CreateIndex
CREATE INDEX "people_tenant_id_idx" ON "project_tracker"."people"("tenant_id");

-- CreateIndex
CREATE INDEX "projects_stage_idx" ON "project_tracker"."projects"("stage");

-- CreateIndex
CREATE INDEX "projects_pm_id_idx" ON "project_tracker"."projects"("pm_id");

-- CreateIndex
CREATE INDEX "projects_tenant_id_idx" ON "project_tracker"."projects"("tenant_id");

-- CreateIndex
CREATE INDEX "project_budget_lines_project_id_idx" ON "project_tracker"."project_budget_lines"("project_id");

-- CreateIndex
CREATE INDEX "project_budget_lines_tenant_id_idx" ON "project_tracker"."project_budget_lines"("tenant_id");

-- CreateIndex
CREATE INDEX "tasks_owner_id_status_idx" ON "project_tracker"."tasks"("owner_id", "status");

-- CreateIndex
CREATE INDEX "tasks_due_date_idx" ON "project_tracker"."tasks"("due_date");

-- CreateIndex
CREATE INDEX "tasks_parent_type_parent_id_idx" ON "project_tracker"."tasks"("parent_type", "parent_id");

-- CreateIndex
CREATE INDEX "tasks_comms_log_id_idx" ON "project_tracker"."tasks"("comms_log_id");

-- CreateIndex
CREATE INDEX "tasks_tenant_id_idx" ON "project_tracker"."tasks"("tenant_id");

-- CreateIndex
CREATE UNIQUE INDEX "pursuits_code_key" ON "project_tracker"."pursuits"("code");

-- CreateIndex
CREATE INDEX "pursuits_stage_idx" ON "project_tracker"."pursuits"("stage");

-- CreateIndex
CREATE INDEX "pursuits_due_date_idx" ON "project_tracker"."pursuits"("due_date");

-- CreateIndex
CREATE INDEX "pursuits_owner_id_idx" ON "project_tracker"."pursuits"("owner_id");

-- CreateIndex
CREATE INDEX "pursuits_tenant_id_idx" ON "project_tracker"."pursuits"("tenant_id");

-- CreateIndex
CREATE INDEX "comms_log_parent_type_parent_id_idx" ON "project_tracker"."comms_log"("parent_type", "parent_id");

-- CreateIndex
CREATE INDEX "comms_log_tenant_id_idx" ON "project_tracker"."comms_log"("tenant_id");

-- CreateIndex
CREATE UNIQUE INDEX "opp_watch_tracks_slug_key" ON "project_tracker"."opp_watch_tracks"("slug");

-- CreateIndex
CREATE INDEX "opp_watch_tracks_tenant_id_idx" ON "project_tracker"."opp_watch_tracks"("tenant_id");

-- CreateIndex
CREATE INDEX "opp_watch_queries_active_idx" ON "project_tracker"."opp_watch_queries"("active");

-- CreateIndex
CREATE INDEX "opp_watch_queries_track_id_idx" ON "project_tracker"."opp_watch_queries"("track_id");

-- CreateIndex
CREATE INDEX "opp_watch_queries_tenant_id_idx" ON "project_tracker"."opp_watch_queries"("tenant_id");

-- CreateIndex
CREATE INDEX "opp_watch_results_status_idx" ON "project_tracker"."opp_watch_results"("status");

-- CreateIndex
CREATE INDEX "opp_watch_results_due_date_idx" ON "project_tracker"."opp_watch_results"("due_date");

-- CreateIndex
CREATE INDEX "opp_watch_results_naics_code_idx" ON "project_tracker"."opp_watch_results"("naics_code");

-- CreateIndex
CREATE INDEX "opp_watch_results_psc_code_idx" ON "project_tracker"."opp_watch_results"("psc_code");

-- CreateIndex
CREATE INDEX "opp_watch_results_pop_state_idx" ON "project_tracker"."opp_watch_results"("pop_state");

-- CreateIndex
CREATE INDEX "opp_watch_results_tenant_id_idx" ON "project_tracker"."opp_watch_results"("tenant_id");

-- CreateIndex
CREATE UNIQUE INDEX "opp_watch_results_query_id_sam_notice_id_key" ON "project_tracker"."opp_watch_results"("query_id", "sam_notice_id");

-- CreateIndex
CREATE UNIQUE INDEX "bl_requests_code_key" ON "project_tracker"."bl_requests"("code");

-- CreateIndex
CREATE INDEX "bl_requests_status_idx" ON "project_tracker"."bl_requests"("status");

-- CreateIndex
CREATE INDEX "bl_requests_due_date_idx" ON "project_tracker"."bl_requests"("due_date");

-- CreateIndex
CREATE INDEX "bl_requests_primary_pm_id_idx" ON "project_tracker"."bl_requests"("primary_pm_id");

-- CreateIndex
CREATE INDEX "bl_requests_responsible_id_idx" ON "project_tracker"."bl_requests"("responsible_id");

-- CreateIndex
CREATE INDEX "bl_requests_tenant_id_idx" ON "project_tracker"."bl_requests"("tenant_id");

-- CreateIndex
CREATE INDEX "audit_logs_entity_type_entity_id_idx" ON "project_tracker"."audit_logs"("entity_type", "entity_id");

-- CreateIndex
CREATE INDEX "audit_logs_created_at_idx" ON "project_tracker"."audit_logs"("created_at");

-- CreateIndex
CREATE INDEX "audit_logs_tenant_id_idx" ON "project_tracker"."audit_logs"("tenant_id");

-- CreateIndex
CREATE INDEX "bl_request_contacts_tenant_id_idx" ON "project_tracker"."bl_request_contacts"("tenant_id");

-- CreateIndex
CREATE INDEX "bl_submissions_bl_request_id_idx" ON "project_tracker"."bl_submissions"("bl_request_id");

-- CreateIndex
CREATE INDEX "bl_submissions_tenant_id_idx" ON "project_tracker"."bl_submissions"("tenant_id");

-- CreateIndex
CREATE UNIQUE INDEX "bl_submissions_bl_request_id_revision_key" ON "project_tracker"."bl_submissions"("bl_request_id", "revision");

-- CreateIndex
CREATE INDEX "bl_submission_lines_bl_submission_id_idx" ON "project_tracker"."bl_submission_lines"("bl_submission_id");

-- CreateIndex
CREATE INDEX "bl_submission_lines_tenant_id_idx" ON "project_tracker"."bl_submission_lines"("tenant_id");

-- AddForeignKey
ALTER TABLE "project_tracker"."projects" ADD CONSTRAINT "projects_pm_id_fkey" FOREIGN KEY ("pm_id") REFERENCES "project_tracker"."people"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "project_tracker"."project_budget_lines" ADD CONSTRAINT "project_budget_lines_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "project_tracker"."projects"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "project_tracker"."tasks" ADD CONSTRAINT "tasks_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "project_tracker"."people"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "project_tracker"."tasks" ADD CONSTRAINT "tasks_comms_log_id_fkey" FOREIGN KEY ("comms_log_id") REFERENCES "project_tracker"."comms_log"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "project_tracker"."pursuits" ADD CONSTRAINT "pursuits_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "project_tracker"."people"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "project_tracker"."opp_watch_queries" ADD CONSTRAINT "opp_watch_queries_track_id_fkey" FOREIGN KEY ("track_id") REFERENCES "project_tracker"."opp_watch_tracks"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "project_tracker"."opp_watch_results" ADD CONSTRAINT "opp_watch_results_query_id_fkey" FOREIGN KEY ("query_id") REFERENCES "project_tracker"."opp_watch_queries"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "project_tracker"."bl_requests" ADD CONSTRAINT "bl_requests_primary_pm_id_fkey" FOREIGN KEY ("primary_pm_id") REFERENCES "project_tracker"."people"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "project_tracker"."bl_requests" ADD CONSTRAINT "bl_requests_responsible_id_fkey" FOREIGN KEY ("responsible_id") REFERENCES "project_tracker"."people"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "project_tracker"."bl_requests" ADD CONSTRAINT "bl_requests_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "project_tracker"."projects"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "project_tracker"."bl_request_contacts" ADD CONSTRAINT "bl_request_contacts_bl_request_id_fkey" FOREIGN KEY ("bl_request_id") REFERENCES "project_tracker"."bl_requests"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "project_tracker"."bl_request_contacts" ADD CONSTRAINT "bl_request_contacts_person_id_fkey" FOREIGN KEY ("person_id") REFERENCES "project_tracker"."people"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "project_tracker"."bl_submissions" ADD CONSTRAINT "bl_submissions_bl_request_id_fkey" FOREIGN KEY ("bl_request_id") REFERENCES "project_tracker"."bl_requests"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "project_tracker"."bl_submission_lines" ADD CONSTRAINT "bl_submission_lines_bl_submission_id_fkey" FOREIGN KEY ("bl_submission_id") REFERENCES "project_tracker"."bl_submissions"("id") ON DELETE CASCADE ON UPDATE CASCADE;
