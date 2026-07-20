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

### 1. SMTP secret  ← TODO: move to OpenBao/VSO
A Gmail **app password** lives in Secret `alertmanager-smtp-gmail`
(key `password`) in `observability`. Created out-of-band:
```bash
printf '%s' '<16-char-app-password>' | kubectl create secret generic \
  alertmanager-smtp-gmail -n observability \
  --from-file=password=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -
```
**Hardening follow-up:** store at `secret/observability/alertmanager-smtp` in
OpenBao and render via a VSO `VaultStaticSecret` (mirror an existing
`*-vso-binding.yaml`), then drop the manual secret. Rotate the app password
(it transited a chat transcript on first setup).

### 2. UFW host rules (node-exporter / kubelet scrape)
The host firewall must let the pod CIDR reach the host metrics ports, else the
node-metrics NetworkPolicy alone isn't enough:
```bash
sudo ufw allow from 10.42.0.0/16 to any port 9100 proto tcp comment 'prometheus node-exporter scrape'
sudo ufw allow from 10.42.0.0/16 to any port 10250 proto tcp comment 'prometheus kubelet scrape'
```
(Applied live 2026-05-30. Fold into the host-bootstrap UFW script for durability.)

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
