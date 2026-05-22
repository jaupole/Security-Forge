# QuickBooks Online integration — setup runbook

How to make the per-org QuickBooks Online (QBO) integration work. The
integration *code* — the OAuth connect flow in Ecosystem Control, the
per-org `organization_accounting_config` table, the Member Hub accounting
outbox worker — is already built and deployed. The only thing standing
between "built" and "working" is the **ecosystem QBO app credentials**:
Control has nowhere to read them until the operator does the steps below.

## Model

There is **one** QBO app registered with Intuit for the whole ecosystem.
Each *organization* then OAuth-connects its own QuickBooks company to
that app — the org admin clicks "Connect QuickBooks" in the Portal, runs
the Intuit consent flow, and Control stores that org's OAuth tokens
(OpenBao-Transit-encrypted) in `organization_accounting_config`.

So there are two credential layers:

| Layer | What | Where it lives |
|---|---|---|
| Ecosystem QBO **app** | `client_id` + `client_secret` (one pair) | OpenBao `secret/apps/control/qbo` — **this runbook** |
| Per-**org** connection | OAuth access/refresh tokens | `organization_accounting_config`, Transit-encrypted — set by the OAuth flow, no manual step |

## One-time setup (operator)

### 1. Register the QBO app at Intuit

1. Sign in at <https://developer.intuit.com> → **Dashboard → Create an app**
   → scope **com.intuit.quickbooks.accounting**.
2. Under **Keys & credentials**, note the **Client ID** and **Client
   Secret**. Intuit gives a separate pair for the **Development**
   (sandbox) and **Production** environments — use the one that matches
   `QBO_ENVIRONMENT` (see step 3).
3. Under **Redirect URIs**, add — exactly, no trailing slash:

   ```
   https://qbo.secforge.dev/callback
   ```

   The callback runs on the dedicated public host `qbo.secforge.dev` —
   `control.secforge.dev` is tailnet-only, so Intuit can't reach it.
   This must byte-match `QBO_REDIRECT_URI` in
   `platform/manifests/control/09-backend-deployment.yaml`; the
   `qbo.secforge.dev` ingress (`13-qbo-ingress.yaml`) rewrites
   `/callback` to the real internal API route.

### 2. Write the credentials to OpenBao

`secret/apps/control/qbo` is a fresh path, so `kv put` (not `patch`):

```bash
bao kv put secret/apps/control/qbo \
  client_id='<Intuit Client ID>' \
  client_secret='<Intuit Client Secret>'
```

Run it with an OpenBao admin token (CLI or the OpenBao UI). The path is
already covered by the `control` policy's `secret/data/apps/control/+`
grant — no policy change needed.

Within `refreshAfter` (60s) the `control-qbo-secrets` VaultStaticSecret
renders the K8s Secret `control-qbo-secrets` in the `control` namespace.

### 3. Pick the environment + roll Control

`QBO_ENVIRONMENT` in `09-backend-deployment.yaml` defaults to `sandbox`.
For real QuickBooks companies, change it to `production` and re-apply the
manifest. Then roll Control so it picks up `control-qbo-secrets`
(envFrom env is read once at pod start):

```bash
kubectl -n control rollout restart deployment/control
kubectl -n control rollout status deployment/control
```

### 4. Verify

`POST /api/v1/orgs/:id/accounting/qbo/connect` now returns an Intuit
`authorizeUrl` instead of a `503 qbo_not_configured`. The quickest check
is from the Portal: an org admin opens **Integrations → QuickBooks →
Connect** and is redirected to Intuit.

## Per-org connection (org admins, ongoing)

In the Portal, **Integrations** page → **Connect QuickBooks** → consent
at Intuit → redirected back. Control stores the org's tokens encrypted.
Member Hub's accounting outbox worker reads the resolved (refreshed)
tokens from Control's `GET /api/v1/system/orgs/:id/accounting-config`
and pushes invoices/payments to QuickBooks.

## Rotation

If Intuit's client secret is rotated, `bao kv put` the new value to the
same path and roll Control. Per-org OAuth tokens self-refresh on read
(`system-accounting-config` refreshes within a 5-minute skew of expiry).

## Why it does not crash when unconfigured

Control's `09-backend-deployment.yaml` consumes `control-qbo-secrets` via
an `optional: true` envFrom. Before step 2, the OpenBao path is absent,
the VaultStaticSecret has no source, the K8s Secret is never created, and
Control starts normally — `env.QBO_CLIENT_ID` is simply unset and the QBO
connect routes return a clean `503 qbo_not_configured`.
