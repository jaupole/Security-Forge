// core-sync.stub.ts — SKELETON of the poller that keeps this app's read-only
// core_* projections current (ADR-0041 pull transport). Copy the STRUCTURE;
// project-manager/src/lib/core-sync.ts is the full reference implementation
// (~350 lines, all three entities). Adapt imports to your app (tx helper,
// service-token client, pinned egress fetch).
//
// Contract:
//  - Pull GET /api/v1/system/core-export?entity=<e>&appId=<app>&cursor=<n>&limit=200
//    with the app's system service token.
//  - Version-guarded upsert: only overwrite when incoming.version is strictly newer.
//  - Per-entity cursor in core_sync_cursor (syncSeq high-water mark).
//  - Every 24h, a full reconcile replays from cursor 0 WITHOUT persisting the
//    intermediate cursor (a crash mid-reconcile must never regress the mark).
//  - Failure posture: log and retry next tick; never crash the process; a
//    missing service-token config just skips the tick; one entity's failure
//    does not block another's.

import { withTx } from '../db/withTx.js';           // sets app.org_id / app.user_id per tx
import { getServiceToken, isServiceTokenConfigured } from './service-token.js';
import { pinnedFetch } from './pinned-egress.js';    // §14 egress allowlist
import { logger } from './logger.js';

const APP_ID = '<app_snake_case>';
const CONTROL_BASE = process.env.CONTROL_API_URL ?? '';
const PAGE_LIMIT = 200;
const POLL_INTERVAL_MS = 60_000;
const POLL_JITTER_MS = 10_000;
const RECONCILE_INTERVAL_MS = 24 * 60 * 60 * 1000;
const NO_ORG_UUID = '00000000-0000-0000-0000-000000000000'; // cursor writes are app-global

type Entity = 'person' | 'client' | 'engagement';
const ENTITIES: Entity[] = ['person', 'client', 'engagement'];

// One page of the export feed. Shape per entity differs (see core-schema.md);
// upsert<Entity> maps camelCase JSON → the snake_case projection columns.
type ExportRow = { id: string; orgId: string; version: number; syncSeq: number; active: boolean; [k: string]: unknown };

async function readCursor(entity: Entity): Promise<number> {
  return withTx(NO_ORG_UUID, async (tx) => {
    const r = await tx.query('SELECT cursor FROM core_sync_cursor WHERE entity_type = $1', [entity]);
    return r.rows[0]?.cursor ?? 0;
  });
}

async function writeCursor(entity: Entity, cursor: number): Promise<void> {
  await withTx(NO_ORG_UUID, async (tx) => {
    await tx.query(
      `INSERT INTO core_sync_cursor (entity_type, cursor, synced_at) VALUES ($1, $2, now())
       ON CONFLICT (entity_type) DO UPDATE SET cursor = EXCLUDED.cursor, synced_at = now()`,
      [entity, cursor],
    );
  });
}

// Version-guarded upsert of one row into its per-org projection. Runs in the
// row's org context so RLS/FORCE-RLS is satisfied.
async function upsertRow(entity: Entity, row: ExportRow): Promise<void> {
  await withTx(row.orgId, async (tx) => {
    // TODO: map `row` to the projection columns for `entity` and upsert with
    //   ... ON CONFLICT (id) DO UPDATE SET ... WHERE core_<e>.version < EXCLUDED.version
    // so an older page can never regress a newer row. See PM's upsert helpers.
  });
}

async function syncEntity(entity: Entity, opts: { reconcile: boolean }): Promise<void> {
  if (!isServiceTokenConfigured()) return; // inert until the system client is provisioned
  let cursor = opts.reconcile ? 0 : await readCursor(entity);
  for (;;) {
    const url = `${CONTROL_BASE}/api/v1/system/core-export?entity=${entity}&appId=${APP_ID}&cursor=${cursor}&limit=${PAGE_LIMIT}`;
    const res = await pinnedFetch(url, { headers: { authorization: `Bearer ${await getServiceToken()}` } });
    if (!res.ok) throw new Error(`core-export ${entity} ${res.status}`);
    const rows = (await res.json()) as ExportRow[];
    if (rows.length === 0) break;
    for (const row of rows) await upsertRow(entity, row);
    cursor = Math.max(...rows.map((r) => r.syncSeq));
    if (!opts.reconcile) await writeCursor(entity, cursor); // reconcile never persists intermediate cursors
    if (rows.length < PAGE_LIMIT) break;
  }
}

// Kick off from server startup. Independent per-entity passes; failures isolated.
export function startCoreSync(): void {
  let lastReconcile = 0;
  const tick = async () => {
    const reconcile = Date.now() - lastReconcile >= RECONCILE_INTERVAL_MS;
    for (const entity of ENTITIES) {
      try {
        await syncEntity(entity, { reconcile });
      } catch (err) {
        logger.warn({ entity, err: String(err) }, 'core-sync tick failed; retrying next interval');
      }
    }
    if (reconcile) lastReconcile = Date.now();
  };
  const schedule = () => setTimeout(async () => { await tick(); schedule(); },
    POLL_INTERVAL_MS + Math.floor(Math.random() * POLL_JITTER_MS)).unref(); // unref: never hold the process open
  schedule();
}
