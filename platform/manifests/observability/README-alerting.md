# Alerting → email (wired 2026-05-30)

All non-Watchdog alerts now notify **jaupole@googlemail.com**. This replaces the
chart-default `null` receiver. Most of the wiring is declarative (the YAML in
this dir + the two ServiceMonitors), but three pieces are environment state
that can't live in git as-is — documented here.

## Declarative (in this repo)
- `09-platform-alerts.yaml` — PrometheusRule `secforge-platform-alerts`. Restored
  the original 4 groups (container pressure/stability, node health, platform
  services) **and** added `secforge-backups` + `secforge-certs`.
- `13-alertmanager-email.yaml` — `AlertmanagerConfig/secforge-email` (email-ops
  receiver, Watchdog→blackhole).
- `14-alerting-egress.yaml` — egress NetworkPolicies: Prometheus→node metrics
  (`:9100`/`:10250`) and Alertmanager→SMTP (`:587`/`:465`).
- `15-loki-ruler-alerts.yaml` — **log-derived** alerts (no metric exists), fired
  by the Loki ruler straight into the same Alertmanager (v2 API). Ruler wiring
  lives in `platform/values/loki.yaml` (`rulerConfig` + `sidecar.rules.folder`);
  rule ConfigMaps are picked up by the chart's `loki_rule`-labelled sidecar.
  First rule: `AuthzUnavailableBurst` (RCA-sso-switcher 2026-07-15 §6.1).
- `../velero/04-servicemonitor.yaml`, `../cert-manager/04-servicemonitor.yaml` —
  make `velero_backup_*` / `certmanager_*` metrics exist.
- `platform/values/kube-prometheus-stack.yaml` — `alertmanagerSpec.alertmanager
  ConfigMatcherStrategy.type: None` (so the AlertmanagerConfig is a catch-all).
  **Apply with a `helm upgrade kps` next deploy** — until then it's a live patch
  on the Alertmanager CR (drift) made via `kubectl patch`.

## Environment state (NOT in git)

### 1. SMTP secret — migrating Gmail → Resend (codified 2026-07-20)
The legacy state is a Gmail **app password** in the manual Secret
`alertmanager-smtp-gmail`. The replacement is fully codified and one-shot:
a **sending-only Resend API key** in OpenBao at
`secret/observability/alertmanager-smtp`, rendered by
`16-alertmanager-smtp-vso-binding.yaml`, consumed by the Resend-switched
`13-alertmanager-email.yaml` (`smtp.resend.com:587`, from `alerts@` on the
platform domain — same verified domain as Control's platform sender, but a
**separate key**, never Control's).

**To execute (next deploy day, needs `openbao-root-token-tmp`):**
1. Create the key in the Resend dashboard (API Keys → permission
   "Sending access").
2. Run `platform/components/07r-alertmanager-email-resend.sh [keyfile]` —
   it stages the key, applies 16- then 13- (in that order: applying 13-
   before the Secret renders invalidates the AlertmanagerConfig and drops
   email routing), verifies with a test alert, and deletes the Gmail Secret.
3. Revoke the Gmail app password (myaccount.google.com/apppasswords) — it
   also transited a chat transcript on first setup.

### 2. UFW host rules (node-exporter / kubelet scrape)
The host firewall must let the pod CIDR reach the host metrics ports, else the
node-metrics NetworkPolicy alone isn't enough. Applied live 2026-05-30;
**codified 2026-07-20** into `platform/components/00-host-bootstrap.sh` (ufw
section), so a host rebuild recreates them.

### 3. Verify end-to-end
```bash
# all targets up (no kubelet/node-exporter down):
kubectl -n observability exec prometheus-kps-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=up==0'
# send a test alert → inbox:
kubectl -n observability exec alertmanager-kps-alertmanager-0 -c alertmanager -- \
  amtool --alertmanager.url=http://localhost:9093 alert add alertname=Test severity=warning
# confirm delivery:
kubectl -n observability logs alertmanager-kps-alertmanager-0 -c alertmanager | grep 'Notify success'
```
