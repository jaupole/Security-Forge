-- db-conformance.sql — read-only introspection for the fleet DB conformance
-- harness (DB-UNIFICATION D9 / specs/data-standards.md §6). Emits typed,
-- pipe-delimited FACT lines; the policy logic (compare vs the app's
-- conformance-manifest.json) lives in db-conformance.sh. This file KNOWS
-- NOTHING about any app — it only reports what the database actually is.
--
-- Run with: psql -X -q -At -v runtime_role='<app_runtime_role>' -f db-conformance.sql
-- (runtime_role optional; '' disables the runtime-role check facts.)
--
-- Fact line grammar (first field is the tag):
--   T|schema|table|enabled|forced|has_org_id|npolicies|gucs|org_index
--   P|schema|table|using_refs_guic|check_refs_guc   (org_isolation policy shape)
--   W|schema|table|grantee|privilege                (UPDATE/DELETE grants, non-owner)
--   O|schema|table|owner
--   S|schema.table.column                           (secret-NAMED column, pre-allowlist)
--   R|rolename|is_superuser|is_bypassrls            (runtime role attributes)
-- Booleans are emitted as t/f (psql native).

\pset footer off

-- ── T: every ordinary user table, with RLS posture + org_id + policy count ────
SELECT 'T'
     , n.nspname
     , c.relname
     , c.relrowsecurity
     , c.relforcerowsecurity
     , EXISTS (SELECT 1 FROM information_schema.columns col
               WHERE col.table_schema = n.nspname
                 AND col.table_name  = c.relname
                 AND col.column_name = 'org_id')
     , (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid)
     , COALESCE((
         SELECT string_agg(DISTINCT g[1], ',')
         FROM pg_policy p,
              LATERAL regexp_matches(
                COALESCE(pg_get_expr(p.polqual, p.polrelid), '') ||
                COALESCE(pg_get_expr(p.polwithcheck, p.polrelid), ''),
                'app\.[a-z_]+', 'g') AS g
         WHERE p.polrelid = c.oid), '')
     , EXISTS (SELECT 1 FROM pg_index i
               JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
               WHERE i.indrelid = c.oid AND a.attname = 'org_id')
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind = 'r'
   AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
 ORDER BY n.nspname, c.relname;

-- ── P: per TABLE, does SOME policy's USING reference the org GUC, and does SOME
--    policy's WITH CHECK reference it? (Not coupled to a policy NAME — apps name
--    the policy differently: org_isolation vs member_hub_isolation vs per-table.)
SELECT 'P'
     , n.nspname
     , c.relname
     , bool_or(COALESCE(pg_get_expr(p.polqual, p.polrelid), '') ~ 'current_setting\(''app\.')
     , bool_or(COALESCE(pg_get_expr(p.polwithcheck, p.polrelid), '') ~ 'current_setting\(''app\.')
  FROM pg_policy p
  JOIN pg_class c ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 GROUP BY n.nspname, c.relname
 ORDER BY n.nspname, c.relname;

-- ── W: UPDATE/DELETE grants to any role that is NOT the table owner ────────────
--    (append-only tables must have none — the shell checks only those.)
SELECT 'W', g.table_schema, g.table_name, g.grantee, g.privilege_type
  FROM information_schema.role_table_grants g
  JOIN pg_class c ON c.relname = g.table_name
  JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = g.table_schema
 WHERE g.privilege_type IN ('UPDATE','DELETE')
   AND g.table_schema NOT IN ('pg_catalog','information_schema')
   AND g.grantee <> pg_get_userbyid(c.relowner)
   AND g.grantee <> 'PUBLIC'
 ORDER BY 2, 3;

-- ── O: table owner (a runtime role must own no org_scoped table — check #4) ────
SELECT 'O', n.nspname, c.relname, pg_get_userbyid(c.relowner)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind = 'r'
   AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
 ORDER BY 1, 2;

-- ── S: columns whose NAME suggests a stored secret (shell applies the allowlist) ─
SELECT 'S', table_schema || '.' || table_name || '.' || column_name
  FROM information_schema.columns
 WHERE table_schema NOT IN ('pg_catalog','information_schema')
   AND column_name ~* 'password|secret|token|api_?key'
   -- allow encrypted/hashed forms and obvious non-secret suffixes (timestamps,
   -- counts, expiries, ids) that merely CONTAIN 'token' etc.
   AND column_name !~* '(_enc|_hmac|_hash|_at|_expires|_expires_at|_count|_version|_id)$'
 ORDER BY 1, 2;

-- ── R: runtime role attributes (check #4: not superuser, not bypassrls) ────────
SELECT 'R', rolname, rolsuper, rolbypassrls
  FROM pg_roles
 WHERE rolname = NULLIF(:'runtime_role', '')
 ORDER BY 1;
