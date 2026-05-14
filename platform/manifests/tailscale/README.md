# Component 10 — Tailscale (operator access mesh)

## What this is

Tailscale daemon installed on the bare-metal Hetzner host as a `systemd` service. Provides a stable WireGuard-based mesh network between the host and operator devices (laptop, phone) regardless of any device's public IP. Replaces the access-control role that Teleport (Phase 8) was originally going to fill.

## Why this is component 10 (before component 11 — Wazuh host agent)

Tailscale is the operator's access path to the host. It needs to be in place *before* anything that locks down public sshd or applies aggressive fail2ban rules — otherwise the operator risks self-banning during the wazuh + fail2ban install. Once 10 is verified working from a second device, components 11 onward run with the safety net of "I can always reach the host via tailnet, even if my public IP just rotated."

This decision supersedes the earlier "wazuh = component 10" instruction.

## What it solves

1. **DHCP rotation problem** — operator's home/office IP changes regularly; can't whitelist a moving target. Tailscale gives the operator's laptop a permanent `100.x.x.x` address that follows it anywhere.
2. **Scanner visibility for admin UIs** — Wazuh / Grafana / OpenBao admin / Keycloak admin should never appear in Shodan / Censys / FOFA. Component `10a-ingress-tailnet-split.sh` patches their Ingresses with a `whitelist-source-range: 100.64.0.0/10` annotation so they only serve traffic sourced from inside the tailnet.
3. **Public sshd elimination** — component `10b-sshd-lockdown.sh` binds `sshd` to the `tailscale0` interface only, then closes port 22 at the Hetzner Cloud Firewall. After that runs, the public internet has no path to SSH at all — opportunistic SSH brute force traffic is reduced to zero.

## Sub-components and execution order

| Script | What it does | When to run |
|---|---|---|
| `10-tailscale.sh` | Adds Tailscale apt repo, installs `tailscale` + `tailscale-archive-keyring`, brings up the daemon. Auth via `TAILSCALE_AUTHKEY` env var (pre-auth key from admin console) OR interactive browser login. | First. Safe — doesn't restrict any existing access. |
| `10a-ingress-tailnet-split.sh` | Patches admin Ingresses (`wazuh.*`, `grafana.*`, `openbao-admin.*`, `auth-admin.*`) with the `whitelist-source-range` annotation. Applies a Kyverno ClusterPolicy that requires the annotation on any Ingress matching admin-shaped hostnames. | After 10 is verified from the operator's laptop. |
| `10b-sshd-lockdown.sh` | Edits `/etc/ssh/sshd_config` to bind sshd to `127.0.0.1` + the Tailscale interface only. Reloads sshd. Prints the exact `hcloud` CLI commands or web-console steps to close port 22 at the Hetzner Cloud Firewall. | After 10 + 10a verified. **REFUSES to run** if Tailscale isn't up — refuses to lock you out. |

`install-all.sh` runs them in alphanumeric order. Each is idempotent.

## What gets the tailnet-only treatment

Per `admin-allowlist-policy.yaml`, an Ingress is admin-shaped (and thus required to have the `whitelist-source-range` annotation) if its hostname starts with one of:

- `wazuh.`
- `grafana.`
- `openbao-admin.` (NOT `openbao.` — the latter could be a future public-facing thing if app workloads ever talk OpenBao directly via HTTPS, though current architecture has them going via cluster-internal Service)
- `auth-admin.` (Keycloak admin console — distinct from `auth.` which is public OIDC)
- `prometheus.`
- `alertmanager.`
- `argocd.` (future, when we get there)
- `kibana.` / `discover.` (future)

Anything else is public by default. To make a *specific page* of an admin app public: split it into a separate Ingress resource with a hostname that doesn't match the admin pattern (e.g. `status.secforge.dev` for a public health page that lives in the same cluster as the admin Wazuh dashboard). The Kyverno policy doesn't fire on hostnames it doesn't recognize.

## What this does NOT do

- **Not a VPN for end users.** Tailscale here is operator-only. End users hit public Ingresses normally; they never see the tailnet. (Tailscale Funnel exists for "expose a tailnet service publicly via Tailscale's edge" but that's a different use case.)
- **Not an authorization layer.** Tailscale gives you network reachability. Once on the tailnet you can hit the admin Ingresses; what you can DO inside Wazuh / Grafana / OpenBao still goes through their respective auth (Keycloak OIDC). ACLs on the tailnet itself are the next-level refinement (per-device, per-user) — for now, default-allow within the tailnet is fine for solo use.
- **Not a backup access path.** If Tailscale's coordination plane is down AND your tailnet peers haven't communicated recently AND public sshd is closed AND you have no Hetzner Cloud Firewall override, you're locked out. The recovery path is the **Hetzner web console** (KVM/rescue mode) — always available regardless of tailnet state. Document the rescue procedure in operations notes; don't rely on never needing it.

## Operational notes

- **Auth keys:** generate from Tailscale admin console → Settings → Keys. Recommend reusable + ephemeral=false for the host (you want it to persist across daemon restarts). Single-use + ephemeral for the operator's laptop is fine.
- **MagicDNS:** enabled by default. Once Tailscale is up, the host is reachable as `<hostname>.<tailnet-name>.ts.net` from any device on the tailnet. Useful but optional — `tailscale ip -4` shows the raw `100.x.x.x` if you prefer addresses.
- **Subnet routing:** off by default. If you ever want the operator's laptop to reach in-cluster Service IPs directly (instead of via ingress), enable subnet routing on the host: `sudo tailscale up --advertise-routes=10.43.0.0/16` (k3s default Service CIDR). For now, going via the ingress hostnames is simpler.
- **Funnel + Serve:** Tailscale's "publish a tailnet service to the public internet" features. **Not used here** — that pattern is for cases where you don't have your own ingress. You already have ingress-nginx + cert-manager, so Funnel would be redundant + introduce another vendor as a man-in-the-middle for public traffic.
- **MFA / SSO:** Tailscale supports OIDC SSO including via Keycloak. Out of scope for tonight; for solo use the default GitHub/Google login is fine. Future improvement: make Tailscale auth go via your own Keycloak (closes the loop on "all auth flows through one IdP").
- **Audit logs:** Tailscale's admin console shows device connections and ACL changes. For Wazuh ingestion, install the Tailscale audit-log streaming integration as a future component. Not in scope tonight.

## Recovery scenarios

**Scenario: I just locked myself out of SSH via 10b-sshd-lockdown.sh and Tailscale isn't connecting from my laptop.**

1. Open the Hetzner Robot console for the bare-metal server: <https://robot.hetzner.com/server>
2. Click the server → "KVM" or "Activate Rescue System" tab.
3. Boot into rescue mode (Linux live system with SSH access via a temporary root password Hetzner emails you).
4. From rescue mode, mount the box's root filesystem, edit `/etc/ssh/sshd_config` to add `ListenAddress 0.0.0.0`, reboot back to normal.
5. SSH back in via public IP, debug Tailscale.

**Scenario: Tailscale daemon is up but my laptop can't reach the host.**

1. Check both ends are visible to the coordination plane: `tailscale status` on both. If the host shows `offline` or `expired`, its key needs renewing — `sudo tailscale up` on the host (interactive browser auth from a different device).
2. Check ACLs in the Tailscale admin console: by default everything in your tailnet can reach everything. If you've added ACLs and one is blocking, the admin console shows recent ACL deny events.
3. Check the Hetzner Cloud Firewall hasn't accidentally blocked UDP 41641 (Tailscale's WireGuard port). Without that, peers fall back to DERP relays, which still works but is slower; if BOTH 41641 and the DERP relay TCP/443 are blocked, peers can't connect.

## Future enhancements (out of scope tonight)

- **`10c-tailscale-acl.sh`** — ACL configuration locking the host to operator-only access (vs. default-allow within tailnet). Useful when more devices land on the tailnet (CI runners, monitoring laptops, family devices).
- **`10d-tailscale-keycloak-sso.sh`** — wire Tailscale's SSO to Keycloak as the OIDC provider so all auth flows live in one IdP.
- **`10e-tailscale-audit-stream.sh`** — Tailscale → Wazuh audit log streaming so device-join / ACL-change events land in the SIEM.
- **Funnel for specific public pages** — Tailscale Funnel as an alternative to a Cloudflare-fronted public ingress. Probably not worth it given you already have ingress-nginx + cert-manager.
