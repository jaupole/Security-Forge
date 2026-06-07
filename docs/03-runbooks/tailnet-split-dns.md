# Tailnet split-DNS for operator hosts

**Problem this solves.** The operator surfaces — `admin`, `control`, `kc`, `bao`,
`grafana`, `wazuh`, `pf` (`.secforge.dev`) — answer **only** on the
`secforge-gateway-tailnet` Istio gateway (enforced by the Kyverno
`admin-ingress-must-be-tailnet-only` policy). Public DNS resolves those names to the
**public** node IP (`65.21.25.40`), where the public gateway has no route and returns a
bare `404` with no `Content-Type`; mobile browsers can't render that and **save it as a
file** ("download on page open"). A laptop avoids this with an `/etc/hosts` entry mapping
the hosts to the tailnet IP — a phone can't, so it needs DNS.

**Fix.** A small `dnsmasq` resolver on the node, bound to the tailnet IP
`100.77.117.112`, returns the tailnet IP for the operator hosts and forwards everything
else. A **Tailscale split-DNS** entry routes `secforge.dev` queries from every tailnet
device (incl. phones) to it — no per-device hosts file.

```
phone (Tailscale) ──*.secforge.dev──▶ dnsmasq @100.77.117.112:53  (authoritative)
                                         ├─ operator host  → 100.77.117.112 (tailnet gateway)
                                         └─ everything else → 65.21.25.40   (public node IP)
```

> **dnsmasq is authoritative for `secforge.dev` and forwards nothing.** Tailscale
> split-DNS routes *all* `*.secforge.dev` here — including the node's own resolved (which
> gets a `~secforge.dev` route to the Tailscale resolver). A forwarder would bounce public
> hosts back through Tailscale → dnsmasq → **infinite loop** (public hosts like
> `auth.secforge.dev` time out, breaking the admin login redirect). So dnsmasq answers
> every name itself: operator hosts → tailnet IP, all others → the public node IP.

## Node side (done 2026-06-07)

1. `apt-get install -y dnsmasq` (systemd-resolved keeps the loopback stub; dnsmasq binds
   only the tailnet IP, so no `:53` conflict).
2. Install the config (source of truth: `platform/host/dnsmasq/secforge-tailnet.conf`):
   ```sh
   sudo cp platform/host/dnsmasq/secforge-tailnet.conf /etc/dnsmasq.d/secforge-tailnet.conf
   ```
3. Reboot resilience (tailscale0 comes up after boot, so don't hard-bind at start):
   the config uses `bind-dynamic`, plus a drop-in
   `/etc/systemd/system/dnsmasq.service.d/10-tailnet.conf`:
   ```ini
   [Unit]
   After=tailscaled.service network-online.target
   Wants=tailscaled.service
   [Service]
   Restart=on-failure
   RestartSec=5
   ```
4. `sudo systemctl daemon-reload && sudo dnsmasq --test && sudo systemctl enable --now dnsmasq`.

Notes: dnsmasq forwards nothing (authoritative for `secforge.dev`) — see the loop warning
above; a forwarder (`server=127.0.0.53` or any resolver) re-enters via Tailscale and loops.
UFW already allows all on `tailscale0`, so no firewall change. The resolver listens **only**
on `100.77.117.112` — not a public open resolver.

## Tailscale side (admin-console, one-time)

Tailscale **admin console → DNS**:
- **Nameservers → Add nameserver → Custom**, IP `100.77.117.112`, toggle **Restrict to
  domain** = `secforge.dev`.
- Ensure **MagicDNS** is **On** (so the override is pushed to devices).
- If you run a restrictive tailnet **ACL**, allow `*:53` to the node (`udp`/`tcp`).

That's it — every tailnet device (laptop, phone) now resolves the operator hosts to the
tailnet gateway. The laptop `/etc/hosts` entries become redundant and can be removed.

## Verify

On the node (or any tailnet device, swapping `@100.77.117.112` for a normal query once
split-DNS is live):
```sh
dig +short admin.secforge.dev  @100.77.117.112   # → 100.77.117.112   (tailnet)
dig +short portal.secforge.dev @100.77.117.112   # → 65.21.25.40      (public node IP)
dig +short AAAA admin.secforge.dev @100.77.117.112   # → (empty: NODATA, no v6 leak)
```
On the phone: open `https://admin.secforge.dev` over Tailscale — the Admin Console loads
instead of downloading a file.

## Adding/removing an operator host

Keep the `address=/…/100.77.117.112` list in sync with the Istio VirtualServices bound
**only** to `secforge-gateway-tailnet`:
```sh
kubectl get virtualservice -A -o jsonpath='{range .items[*]}{.spec.gateways}{" | "}{.spec.hosts}{"\n"}{end}' | grep tailnet
```
Edit `platform/host/dnsmasq/secforge-tailnet.conf`, re-copy to `/etc/dnsmasq.d/`, and
`sudo systemctl restart dnsmasq`.
