-- verify-control-force-rls-posture.sql
--
-- POST-RESTORE go/no-go gate for the control-plane DB's FORCE-RLS posture
-- (audit EC-003 / SC-3.4 / R4, cutover 2026-06-02).
--
-- Run this as a SUPERUSER against a restored control DB BEFORE pointing the
-- app at it (see docs/03-runbooks/control-db-restore.md). On the single node
-- the superuser path is `kubectl exec <primary> -c postgres -- psql -U postgres
-- -d control` (local socket / peer auth — works even with
-- enableSuperuserAccess:false). The restore drill 09i-control-restore-drill.sh
-- runs this automatically against a throwaway recovered cluster.
--
-- WHY this exists: physical (barman) restore preserves ownership + FORCE +
-- policies by construction, so a POST-cutover restore is sound — but a restore
-- from a PRE-cutover backup silently brings back the old `control`-owned,
-- FORCE-disabled posture and defeats tenant isolation. The app's runtime gate
-- (ecosystem-control src/api/db-assert.ts::assertForceRlsPosture +
-- db-exempt.ts::assertExemptReaderReachable) is the fail-closed backstop, but
-- it only fires at the next pod restart and does NOT check the 061 exempt
-- grants / control_reader. This script is the operator-facing, restore-time
-- equivalent and DOES check them. It is the SQL sibling of db-assert.ts and
-- mirrors the assertions in ecosystem-control/scripts/validate-force-rls.mjs.
--
-- DESIGN: catalog-driven invariants, not a hardcoded table list — so it does
-- not drift as RLS tables are added. The invariant is:
--   "every RLS-enabled public table is FORCE'd AND owned by control_owner",
-- plus a count floor (>=21, the cutover baseline) that trips if a table loses
-- RLS entirely (which would drop it out of the invariant set).
--
-- Every check RAISES on violation; run with ON_ERROR_STOP so the FIRST failure
-- exits the script non-zero:
--     psql -U postgres -d control -v ON_ERROR_STOP=1 -f verify-control-force-rls-posture.sql

\set ON_ERROR_STOP on
\timing off
\echo '== control-db FORCE-RLS posture verification =='

-- 1. Runtime role `control`: non-super, non-bypassrls (else FORCE is moot).
DO $$
DECLARE r record;
BEGIN
  SELECT rolsuper, rolbypassrls INTO r FROM pg_roles WHERE rolname = 'control';
  IF NOT FOUND THEN RAISE EXCEPTION 'role "control" missing'; END IF;
  IF r.rolsuper      THEN RAISE EXCEPTION 'control is SUPERUSER — RLS is bypassed'; END IF;
  IF r.rolbypassrls  THEN RAISE EXCEPTION 'control has BYPASSRLS — RLS is bypassed'; END IF;
  RAISE NOTICE 'OK  control: non-super, non-bypassrls';
END $$;

-- 2. The cutover role set exists with the right shape.
DO $$
DECLARE r record;
BEGIN
  SELECT rolcanlogin, rolbypassrls, rolsuper INTO r FROM pg_roles WHERE rolname = 'control_owner';
  IF NOT FOUND THEN RAISE EXCEPTION 'role "control_owner" missing'; END IF;
  IF r.rolcanlogin            THEN RAISE EXCEPTION 'control_owner can LOGIN (must be NOLOGIN — nobody connects as the owner)'; END IF;
  IF r.rolbypassrls OR r.rolsuper THEN RAISE EXCEPTION 'control_owner has BYPASSRLS/SUPERUSER'; END IF;

  SELECT rolbypassrls, rolsuper INTO r FROM pg_roles WHERE rolname = 'control_reader';
  IF NOT FOUND THEN RAISE EXCEPTION 'role "control_reader" missing'; END IF;
  IF r.rolbypassrls OR r.rolsuper THEN RAISE EXCEPTION 'control_reader has BYPASSRLS/SUPERUSER'; END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'control_migrator') THEN
    RAISE EXCEPTION 'role "control_migrator" missing';
  END IF;
  IF NOT (pg_has_role('control_migrator', 'control', 'MEMBER')
          AND pg_has_role('control_migrator', 'control_owner', 'MEMBER')) THEN
    RAISE EXCEPTION 'control_migrator is not a member of BOTH control and control_owner';
  END IF;
  RAISE NOTICE 'OK  roles: control_owner(NOLOGIN), control_reader, control_migrator(member of control+control_owner)';
END $$;

-- 3. INVARIANT: every RLS-enabled public table is FORCE'd AND owned by control_owner.
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(
           c.relname || ' (forced=' || c.relforcerowsecurity::text
             || ', owner=' || pg_get_userbyid(c.relowner) || ')', ', ')
    INTO bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity
     AND (NOT c.relforcerowsecurity OR pg_get_userbyid(c.relowner) <> 'control_owner');
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'RLS table(s) not FORCE''d or not owned by control_owner: %', bad;
  END IF;
  RAISE NOTICE 'OK  invariant: every RLS table is FORCE + control_owner-owned';
END $$;

-- 4. control OWNS NONE of the RLS tables (FORCE binds the owner, but only if
--    the app does not connect AS the owner).
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'public' AND c.relrowsecurity
     AND pg_get_userbyid(c.relowner) = 'control';
  IF n > 0 THEN RAISE EXCEPTION 'control owns % RLS table(s) — pre-cutover posture restored!', n; END IF;
  RAISE NOTICE 'OK  control owns none of the RLS tables';
END $$;

-- 5. Count floor: >=21 FORCE'd control_owner RLS tables (the 2026-06-02 cutover
--    baseline). The count only GROWS as tables are added; BELOW 21 means a
--    table lost RLS (dropped out of the invariant set in check 3).
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'public' AND c.relkind = 'r'
     AND c.relrowsecurity AND c.relforcerowsecurity
     AND pg_get_userbyid(c.relowner) = 'control_owner';
  IF n < 21 THEN
    RAISE EXCEPTION 'only % FORCE''d control_owner RLS tables (cutover baseline is 21 — did a table lose RLS?)', n;
  END IF;
  RAISE NOTICE 'OK  count: % FORCE''d control_owner RLS tables (>= 21)', n;
END $$;

-- 6. Security-critical non-RLS objects are owned by control_owner (so control
--    cannot DISABLE RLS / DROP a policy / tamper the audit chain).
DO $$
DECLARE o text;
BEGIN
  FOREACH o IN ARRAY ARRAY['audit_log', 'schema_migrations'] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relname = o
         AND pg_get_userbyid(c.relowner) = 'control_owner'
    ) THEN
      RAISE EXCEPTION '% is not owned by control_owner', o;
    END IF;
  END LOOP;
  RAISE NOTICE 'OK  ownership: audit_log + schema_migrations are control_owner';
END $$;

-- 7. Policies present: org_isolation (per-tenant gate) + exempt_read (the 061
--    cross-org read path). A restore that lost 061 state passes the boot gate
--    yet silently breaks withExemptRead — this catches it.
DO $$
DECLARE iso int; ex int;
BEGIN
  SELECT count(*) INTO iso FROM pg_policies WHERE schemaname = 'public' AND policyname = 'org_isolation';
  IF iso < 1 THEN RAISE EXCEPTION 'no org_isolation policies present'; END IF;
  SELECT count(*) INTO ex  FROM pg_policies WHERE schemaname = 'public' AND policyname = 'exempt_read';
  IF ex < 1 THEN RAISE EXCEPTION 'no exempt_read policies present (061 state lost — withExemptRead would break)'; END IF;
  RAISE NOTICE 'OK  policies: % org_isolation, % exempt_read', iso, ex;
END $$;

-- 8. FUNCTIONAL: FORCE actually binds `control`. With the all-zeros org
--    sentinel set (the db-tx.ts pattern — avoids the ''::uuid cast throw a
--    leaked GUC would cause), a sample org_isolation table returns 0 rows for
--    control (it is a non-owner, so it sees only its own org — and no row has
--    the sentinel org).
DO $$
DECLARE t text; n bigint;
BEGIN
  SELECT c.relname INTO t
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'public' AND c.relrowsecurity AND c.relforcerowsecurity
     AND EXISTS (SELECT 1 FROM pg_policies p
                  WHERE p.schemaname = 'public' AND p.tablename = c.relname
                    AND p.policyname = 'org_isolation')
   ORDER BY c.relname LIMIT 1;
  IF t IS NULL THEN RAISE EXCEPTION 'no org_isolation-protected table found for the functional check'; END IF;
  -- Set BOTH sentinels (the db-tx.ts pattern): some org_isolation policies also
  -- reference app.user_id (e.g. organization_memberships), and an unset GUC is
  -- '' which throws on ::uuid. All-zeros is a valid UUID matching no real row.
  PERFORM set_config('app.org_id',  '00000000-0000-0000-0000-000000000000', false);
  PERFORM set_config('app.user_id', '00000000-0000-0000-0000-000000000000', false);
  SET ROLE control;
  EXECUTE format('SELECT count(*) FROM public.%I', t) INTO n;
  RESET ROLE;
  IF n <> 0 THEN RAISE EXCEPTION 'control saw % row(s) in % with the sentinel org — FORCE is NOT binding!', n, t; END IF;
  RAISE NOTICE 'OK  functional: control sees 0 rows in % with sentinel org (FORCE binds the non-owner)', t;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RAISE;
END $$;

-- 9. FUNCTIONAL: control_reader can read an exempt table (the withExemptRead
--    cross-org path). Proves the role + 061 grants + exempt_read policy line up.
DO $$
DECLARE t text; n bigint;
BEGIN
  SELECT p.tablename INTO t FROM pg_policies p
   WHERE p.schemaname = 'public' AND p.policyname = 'exempt_read'
   ORDER BY p.tablename LIMIT 1;
  IF t IS NULL THEN RAISE EXCEPTION 'no exempt_read table found'; END IF;
  SET ROLE control_reader;
  EXECUTE format('SELECT count(*) FROM public.%I', t) INTO n;
  RESET ROLE;
  RAISE NOTICE 'OK  functional: control_reader read % (% row(s), cross-org)', t, n;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RAISE;
END $$;

\echo ''
\echo 'PASS — control-db FORCE-RLS posture verified. Safe to point the app at this DB.'
