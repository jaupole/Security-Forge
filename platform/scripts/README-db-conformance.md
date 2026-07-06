# DB Conformance Harness

The "teeth" of the DB-unification data standards (DB-UNIFICATION D9 /
`db-unification/specs/data-standards.md §6`). It introspects an app database
(read-only) and **fails** when reality diverges from that app's declared
`db/conformance-manifest.json` — killing the class of bug where an org-scoped
table is added to the DB but forgotten in a hand-kept list
(BM `ORG_SCOPED_MODELS`, Control `FORCE_RLS_TABLES`).

## Files
- `db-conformance.sql` — pure, app-agnostic read-only introspection. Emits typed
  `FACT` lines (see the header). Knows nothing about any app.
- `db-conformance.sh` — the policy engine: runs the SQL, loads the app manifest,
  applies the checks, exits nonzero on any **finding** (warnings don't fail).

## Severity
- **✗ finding (exit 1)** — isolation/secret/classification defects: unclassified
  table, org_scoped without FORCE RLS, no GUC-referencing policy, GUC mismatch,
  append-only with UPDATE/DELETE grants, runtime role super/bypassrls/owner,
  un-allowlisted secret-named column, real migration-number collision.
- **! warning (exit 0)** — standards/perf gaps that don't weaken isolation
  (e.g. org_scoped table missing an `org_id` index). Reported every run, tracked
  for cleanup, non-blocking.

## Run it

Per-cluster on the box (read-only against live prod):
```
sudo bash db-conformance.sh --cluster \
  --ns member-hub --pod member-hub-db-1 --db member_hub \
  --manifest /path/to/member-hub/db/conformance-manifest.json \
  --migrations /path/to/member-hub/migrations \
  --runtime-role member_hub_app
```

In an app's CI (against the migration-built DB):
```
bash db-conformance.sh --ci --dsn "$DATABASE_URL" \
  --manifest db/conformance-manifest.json --migrations <migrations-dir> \
  --runtime-role <app>_app
```

Evaluate pre-captured facts (CI cache / offline):
```
psql ... -f db-conformance.sql > facts.txt          # capture once
bash db-conformance.sh --facts-file facts.txt --manifest ... --migrations ...
```

## Manifest schema
`<app-repo>/db/conformance-manifest.json` — every table in the DB must land in
exactly one bucket:

| Key | Meaning |
|---|---|
| `org_scoped` | tenant table: FORCE RLS + org_id + GUC policy + (warn) org index |
| `org_scoped_indirect` | FORCE+policy but scoped via FK, no direct org_id column |
| `rls_exempt` | RLS is not the boundary (worker/outbox, session store, global cache) — each with a rationale string |
| `append_only` | INSERT-only: no UPDATE/DELETE grants beyond owner |
| `global_allowlist` | platform/global, non-org (migrations table, platform config) |
| `secret_allowlist` | `schema.table.col` → why a `*token*`-named column is not a stored credential |
| `migration_grandfather` | numeric prefixes that legitimately duplicate (predate the rule) |

## Baseline (captured 2026-07-06, first run)
- **proposal_forge, business_manager**: conformant, 0 warnings.
- **project_manager**: conformant, 30 org_id-index warnings (index sweep tracked).
- **control**: 1 finding — `platform_ticket_email_config.postmark_server_token`
  plaintext (backlog #34, P0 §7.3); 5 index warnings.
- **member_hub**: 4 findings — `automations`, `automation_rules`, `invoices`,
  `org_invoice_settings` ENABLE-not-FORCE RLS (P0 §7.1); 2 index warnings.

The two finding sets are exactly the P0 §7 security fixes; when those land the
harness is green fleet-wide.

## Wire-up (pending)
- App CI job (each repo) + post-deploy step in `deploy-app.yml` + weekly cron on
  the box. See `db-unification/PROGRESS.md`.
