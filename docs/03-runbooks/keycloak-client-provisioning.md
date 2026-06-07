# Keycloak Client Provisioning — Path A pattern

> Companion: [keycloak-operations.md](./keycloak-operations.md), [PLAN.md kcadm-admin migration phase](../../PLAN.md).

This runbook covers **how** to provision new Keycloak clients via committed scripts during the interim period before the kcadm-admin migration phase ships. Phase 7 and earlier scripts use this pattern. The kcadm-admin migration phase (planned post-Phase-7) consolidates everything described here behind a single durable provisioning path.

---

## Why we need a workaround at all

`kcadm.sh` 26.x removed the `--otp` flag (see auto-memory `kcadm_26x_no_totp.md`). Direct user-with-TOTP authentication is no longer viable:

- Plain password fails when the realm enforces direct-grant OTP
- Password+TOTP-concatenation works but is fragile (the 6-digit code expires within ~30s; CI cannot supply one; scripts must be re-invoked with a fresh code on retry)

Until the migration phase replaces every kcadm script with a single durable provisioning surface, the working pattern is **service-account authentication via a per-task throwaway client**. The Phase 6b-0 spike (`infrastructure/keycloak/spike-token-exchange.sh`) was the first instance; Phase 7's scripts (`grafana.sh`, `wazuh-dashboard.sh`) clone it.

---

## The Path A pattern

For each new provisioning script:

### Step 1 — Create a throwaway service-account client in `master` (manual, via UI)

The kcadm-admin client itself cannot bootstrap itself; the operator creates it once via the master-realm admin UI:

1. **Clients → Create client**
   - Client type: `OpenID Connect`
   - Client ID: `kcadm-<task>-tmp` (e.g., `kcadm-grafana-tmp`, `kcadm-wazuh-tmp`) — **the `-tmp` suffix is the migration-time grep target; do not omit it**
   - Always-display-in-UI: off
2. **Capability config**
   - Client authentication: ON
   - Authentication flow: only `Service accounts roles`
3. **Service accounts roles tab** — assign client roles on the **target-realm** (e.g., `platform-realm`):
   - `view-realm`
   - `view-clients`
   - `query-clients`
   - `manage-clients`
   - For wider work, optionally: `view-authorization`, `manage-authorization`
4. **Credentials tab** — copy the client secret into `KCADM_CLIENT_SECRET` for the script.

**Naming convention is the inventory marker.** Earlier guidance proposed a Keycloak client attribute (`secforge.dev/temporary: yes`) for the grep target, but Keycloak 26.x relocated the per-client Attributes UI to Advanced / JSON-only. Rather than chase the moving UI, we use the `kcadm-*-tmp` clientId suffix as the durable convention. The migration phase's inventory step enumerates kcadm-using clients via `kcadm get clients -r master --query 'clientId LIKE %-tmp'` (or equivalent jq filter).

### Step 2 — Author the provisioning script

Use `infrastructure/keycloak/spike-token-exchange.sh` as the template. The mandatory shape:

```bash
KCADM_CLIENT_ID=kcadm-<task>-tmp

kcadm_auth() {
    if kcadm config credentials \
            --server http://localhost:8080 --realm master \
            --client "$KCADM_CLIENT_ID" --secret "$KCADM_CLIENT_SECRET" \
            >/dev/null 2>&1; then
        # ok
        return
    fi
    # error path: client missing, secret rotated, or roles incomplete
    exit 1
}
```

Best-practice script structure:
- Idempotent: re-running produces no diffs
- Reads existing client_secret if present; only regenerates if absent
- Aborts early if a prerequisite realm role (e.g., `platform_admin`) is missing rather than silently masking a Phase-N dependency
- Final STDOUT prints the captured secret in a banner-bordered block so the operator can `tee` it once

### Step 3 — Run the script

```bash
KCADM_CLIENT_SECRET='<from-master-realm-UI>' \
    bash infrastructure/keycloak/clients/<task>.sh
```

### Step 4 — Tear down the throwaway client at end of migration phase

The kcadm-admin migration phase will:
1. Replace each script's `kcadm_auth` with a centralized entry
2. Grep for clients tagged `secforge.dev/temporary=yes` in the master realm
3. Delete them all in one pass

Until then, the throwaway clients **stay** so the scripts remain re-runnable for fresh-cluster bootstraps.

---

## Inventory

Audit the master realm periodically; every kcadm-temporary client should be on this list and should still be in active use:

| Client | Created by | Used by | Tear-down trigger |
|---|---|---|---|
| `kcadm-spike` | Operator (manual UI), Phase 6b-0 | `infrastructure/keycloak/spike-token-exchange.sh` | Should already be deleted; spike concluded. **If still present in master realm: drift — remove.** |
| `kcadm-grafana-tmp` | Operator (manual UI), Phase 7.3 | `infrastructure/keycloak/clients/grafana.sh` | kcadm-admin migration phase |
| `kcadm-wazuh-tmp` | Operator (manual UI), Phase 7.2 | `infrastructure/keycloak/clients/wazuh-dashboard.sh` (TBD) | kcadm-admin migration phase |

Find all of them in one query:

```bash
kubectl exec -n keycloak keycloak-0 -c keycloak -- \
    /opt/keycloak/bin/kcadm.sh get clients -r master \
    --fields clientId,id 2>/dev/null \
    | jq '[.[] | select(.clientId | endswith("-tmp"))]'
```

---

## What this pattern is NOT

- **Not a replacement for the kcadm-admin migration.** It's a controlled workaround. Every cycle this stays in place adds clean-up debt.
- **Not appropriate for permanent operational scripts** — only for one-time provisioning. Once a Phase-N component's OIDC client exists, day-to-day operations on that component (logging in, rotating secrets) do not use this path.
- **Not a security model decision.** The throwaway clients have realm-scoped admin power for as long as they live. Treat their secrets like the master-realm admin password.
