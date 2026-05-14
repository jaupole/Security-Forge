# SecForge platform — production install orchestrator

Single-source-of-truth orchestration layer for deploying the SecForge platform to production (currently: bare metal Hetzner box, single-node k3s).

This is a **separate, parallel** structure to `infrastructure/`, which targets the local edition (Docker Desktop K8s + `secforge.local`). Both share the same component charts and CRD-level resources where possible; they diverge in values, ingress hostnames, and trust-domain configuration.

## Quick reference

| File / dir | Purpose |
|---|---|
| `globals.env` | Single source of truth — change one line to change the public domain |
| `install-all.sh` | Run every component in order (idempotent; safe to re-run) |
| `components/0X-<name>.sh` | Individual component installs (numeric prefix = order) |
| `values/<component>.yaml` | Helm values, parameterized with `${VAR}` |
| `manifests/<component>/*.yaml` | Non-Helm K8s resources (CRs, NetworkPolicies, etc.), also parameterized |
| `lib/render.sh` | Render a single template via envsubst |
| `lib/install-helm.sh` | Helm install wrapper with values rendering |
| `lib/apply-manifest.sh` | kubectl apply wrapper with manifest rendering |

## How it works

Every values file and manifest may contain `${VAR}` placeholders. At install time, `lib/install-helm.sh` and `lib/apply-manifest.sh` source `globals.env` and substitute placeholders via `envsubst` before handing files to `helm` or `kubectl`.

Example:

```yaml
# values/keycloak.yaml
hostname:
  hostname: auth.${DOMAIN}    # → auth.secforge.dev at install time
```

To change the public domain in production: edit `globals.env`, run `./install-all.sh`. Helm rolls every chart whose values referenced `${DOMAIN}` with the new value.

## Component install order

Encoded in `components/` filename prefixes:

1. `01-cloudnativepg.sh` — Postgres operator (foundational; many others depend on it)
2. `02-spire.sh` *(pending)* — workload identity
3. `03-keycloak.sh` *(pending)* — identity provider (depends on 01)
4. `04-spicedb.sh` *(pending)* — authorization (depends on 01)
5. `05-openbao.sh` *(pending)* — secrets (depends on 01, 02)
6. `06-istio.sh` *(pending)* — service mesh
7. `07-observability.sh` *(pending)* — Prometheus, Loki, Tempo, Grafana, Wazuh
8. `08-teleport.sh` *(pending)* — privileged access
9. `09a-velero.sh` / `09b-cnpg-backups.sh` / `09c-velero-tune.sh` — backups
10. `10-tailscale.sh` + `10a-ingress-tailnet-split.sh` + `10b-sshd-lockdown.sh` — operator-access mesh (Tailscale on the host) + admin-Ingress allowlist (Kyverno-enforced `whitelist-source-range: 100.64.0.0/10` on `wazuh.*`/`grafana.*`/`openbao-admin.*`/`auth-admin.*`/etc.) + sshd bound to tailnet only. Solves the DHCP-rotating-operator-IP problem and removes scanner visibility for admin UIs. See `manifests/tailscale/README.md` for design rationale.
11. `11-wazuh-host-agent.sh` + `11a-auditd.sh` + `11b-fail2ban.sh` — host-side detection capability buildout (native Wazuh agent on the bare-metal host; supersedes the in-cluster `07b-wazuh-agent.sh` DaemonSet pattern). See `manifests/wazuh-host-agent/README.md` for design rationale.

> **Note on `07b-wazuh-agent.sh`:** the in-cluster DaemonSet pattern is superseded by component 11. The DaemonSet works for FIM and pod-log tailing but several Wazuh modules can't see across the pod-namespace boundary (network interfaces, processes, package DB, full rootcheck, SCA, auditd integration). Component 11 installs the agent natively on the host so all those modules work. Once 11 is verified to be reporting, **remove `07b-wazuh-agent.sh` from `components/`** so `install-all.sh` stops re-deploying the DaemonSet on every run; component 11 already tears down the DaemonSet artifacts at the end of each install (gated on the native agent reporting Active).

> **Component 10 ordering rationale:** Tailscale lands BEFORE wazuh because component 11b (fail2ban) and 10b (sshd lockdown) both rely on the operator having a stable access path that survives DHCP rotation and an aggressively-locked-down sshd. Run the install order strictly: 10 → verify tailnet reachability from your laptop → 10a → 10b → 11 → 11a → 11b. Skipping verification between 10 and 10b risks self-locking out of the host.

## Relationship to `infrastructure/`

`infrastructure/` (existing, untouched):
- Targets local Docker Desktop K8s
- Domain hardcoded as `secforge.local`
- Trust domain hardcoded as `spiffe://secforge.local`
- Has individual `apply.sh` scripts and values for hands-on local development

`platform/` (this directory):
- Targets production k3s on bare metal
- Domain is `${DOMAIN}` (currently `secforge.dev`, set in `globals.env`)
- Trust domain is `${SPIFFE_TRUST_DOMAIN}` (set to `spiffe://secforge.platform` — deliberately decoupled from public DNS so domain changes don't force SVID re-issuance)
- Single orchestrator (`install-all.sh`) for deterministic cluster builds

## Required tooling on the install host

- `helm` (v3.16+)
- `kubectl` (matching cluster minor version)
- `envsubst` (provided by `gettext-base` package on Debian/Ubuntu)
- `bash` (4.x+)

The k3s install in Phase A already includes `kubectl`. `helm` was installed in the same phase. `envsubst` is in `gettext-base` (typically already present on Ubuntu but install if missing: `sudo apt install -y gettext-base`).

## Idempotency

Every install script uses `helm upgrade --install` and `kubectl apply`, so re-running `install-all.sh` after editing values or globals applies only the diffs. There is no destructive action in any component script.

## Testing changes

After editing values or globals:

```bash
# Render a values file to inspect the resolved output (no install)
./lib/render.sh values/keycloak.yaml | less

# Run a single component
bash components/03-keycloak.sh

# Run the whole stack
./install-all.sh
```
