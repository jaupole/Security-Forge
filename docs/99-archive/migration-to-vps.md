> 🗄️ **ARCHIVED 2026-06-07 — local-first / build-era document.**
> This describes the original Docker Desktop / WSL2 / `secforge.local` build, **not** the current
> bare-metal `secforge-prod` deployment. Kept for history only. For current state see `PLAN.md`,
> `docs/01-architecture/`, and `docs/06-reference/operator-backlog.md` (archive index: `docs/99-archive/README.md`).

# Migration Playbook: Local → Single VPS / Homelab Server

> **Snapshot date: 2026-05-04 (post-Phase 9).** This playbook assumes Phases 1–9 of the local build are complete: SPIRE workload identity, Keycloak with TOTP+recovery codes, SpiceDB + AuthZEN façade, OpenBao with two-instance Transit auto-unseal, Istio Ambient (PERMISSIVE), the BFF + api-auth library + outbound-secrets pattern, the full observability stack (Loki/Tempo/Prometheus/Wazuh), Teleport CE with GitHub OAuth, and the Hello World end-to-end checkpoint. Phase 10 (Proposal Forge + Project Tracker integration) follows the same per-app pattern in the cloud destination — repeat the steps once per app rather than restarting from Phase 1. If your local cluster is in an earlier state, complete the missing phases locally first; this playbook is not a shortcut.

This is the playbook for moving the SecForge platform from your local Docker Desktop Kubernetes cluster to a single self-hosted server — either a VPS (Hetzner, OVH, DigitalOcean Droplet, Linode, etc.) or a homelab box you control.

This is the **cheapest production-realistic destination**. Sustained ~$30-100/month depending on the server. Acceptable for early customers / pilots / personal use. Not appropriate for compliance-bound workloads (HIPAA, PCI, etc.) without significant additional hardening.

---

## When to choose this path

Pick VPS / homelab if any of these apply:
- Cost is a hard constraint and AWS would be wasteful at your scale
- You want complete control over the substrate (no cloud-provider vendor lock-in)
- You're comfortable being your own SRE
- Your compliance requirements don't mandate cloud-provider attestation
- You're piloting with a few customers and want to keep the cost predictable

Don't pick this if:
- You need multi-region failover
- You need the SOC 2 / ISO 27001 audit trail that managed cloud providers give you
- You don't want to be on call for hardware failures
- Your customers will ask "where is my data hosted" and "AWS US-East" is the easier answer

---

## Server sizing recommendations

For the full platform + 3 apps with light load:

| Tier | Specs | Cost (approximate) | Notes |
|---|---|---|---|
| **Minimum** | 8 vCPU / 32 GB / 200 GB NVMe | ~$50/month (Hetzner CCX23) | Tight; works |
| **Comfortable** | 16 vCPU / 64 GB / 500 GB NVMe | ~$100/month (Hetzner CCX33) | Recommended starting point |
| **With headroom** | 32 vCPU / 128 GB | ~$200/month | If you have many customers |

Recommend Hetzner Cloud or OVH for cost-effectiveness. AWS Lightsail is more expensive per GB. DigitalOcean Droplets are simpler but pricier than Hetzner.

---

## Major substrate changes

| Local | VPS Production |
|---|---|
| Docker Desktop K8s | k3s (single-node) or k3s + lightweight HA across 2-3 nodes |
| hosts file DNS | Real DNS via your registrar (or Cloudflare for fast updates) |
| mkcert local CA | Let's Encrypt via cert-manager (HTTP-01 or DNS-01 challenge) |
| File-based KMS keys | OpenBao Transit + key derivation from a hardware-backed master key (TPM if available, or scripted-recovery from a backup) |
| MinIO local | MinIO (same!) — works great on VPS |
| Postgres pods | Postgres pods (still in-cluster) — at this scale, no benefit to managed Postgres |
| No backups | Automated backups to off-server storage (Backblaze B2, S3, etc.) |
| No monitoring of host | node-exporter + Prometheus alerting on disk full, etc. |
| No secrets backup | OpenBao snapshot to off-server storage |
| Single point of failure: laptop off | Single point of failure: server down (need DNS failover or accept downtime) |

---

## Phased migration

### Phase A: Prepare the server (1 day)

1. Provision the server with Ubuntu 24.04 LTS
2. Run security hardening: ufw firewall, fail2ban, automatic security updates, SSH key-only auth, disable root SSH, change default SSH port (security through obscurity but reduces noise)
3. Install k3s:
   ```bash
   curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.31.x sh -s - \
     --disable traefik \
     --disable servicelb \
     --write-kubeconfig-mode 644
   ```
   (We disable traefik and servicelb so we can install ingress-nginx and MetalLB to match local.)
4. Install MetalLB if you want LoadBalancer services to work (skip for single-node).
5. Get kubeconfig: `cat /etc/rancher/k3s/k3s.yaml` (replace `127.0.0.1` with the server's public IP for remote access).

### Phase B: DNS and TLS (1 day)

1. Point your real domain (e.g., `secforge.io`) to the server's IP. A records for `auth`, `app`, `api`, `bao`, `wazuh`, `tp`, `pf`, `pt`, `pm`.
2. Install cert-manager (same as local).
3. Replace the mkcert ClusterIssuer with a Let's Encrypt ClusterIssuer (use ACME HTTP-01 if your server is publicly reachable on :80; DNS-01 if not).
4. Test certificate issuance.

### Phase C: Re-deploy the platform (3-5 days)

For each phase from the local build, re-apply with these substrate changes:

- **Phase 1 (Foundation)**: Same Helm charts. Update ingress class. Use Let's Encrypt issuer.
- **Phase 2 (SPIRE)**: Trust domain change: `spiffe://<your-domain>` (e.g., `spiffe://secforge.io`). Re-generate the upstream CA root. **Important**: also re-issue all SVIDs since trust domain changed.
- **Phase 3 (Keycloak)**: Same. Update redirect URIs from `*.secforge.local` to `*.secforge.io`. Realm exports from local can be imported. **Hardware FIDO2 keys required at this point** — per [ADR-0002](../02-decisions/0002-local-passkey-via-windows-hello.md), local edition uses Windows Hello as the admin passkey, but VPS deployment is a reversal trigger. Before cutover: order two Token2 PIN+ keys (or YubiKey 5 / SoloKey v2), register both to the admin account in Keycloak, then tighten the WebAuthn policy (`Attestation Conveyance: direct`, `Authenticator Attachment: cross-platform` for the admin role). The Windows Hello credential can be removed or kept as a developer-machine-only tertiary factor. Verify the break-glass account credentials are still recoverable and stored offline.
- **Phase 4 (SpiceDB)**: Schema is portable. Relationships are portable. Just re-apply.
- **Phase 5 (OpenBao)**: This is the trickiest. The local "two OpenBao" pattern works, but consider: do you want the seal-OpenBao on the same server (single point of failure) or external? For a single-server VPS, accept the SPOF and document it. For a 2-node setup, put seal-OpenBao on the second node.
- **Phase 6 (Istio + BFF)**: Same. BFF code unchanged. Update env vars for new hostnames.
- **Phase 7 (Observability)**: Same. Wazuh's resource needs are the same.
- **Phase 8 (Teleport)**: Same. Now Teleport actually matters because direct kubectl access requires SSH to the VPS, which Teleport can mediate.
- **Phase 9-10 (Apps)**: Same. App code unchanged.

### Phase D: Backups (2 days)

This is what local doesn't have. Set up:

1. **Velero** for K8s resource + PV backups to Backblaze B2 (or S3-compatible storage on a different provider — never the same provider as your primary).
2. **Postgres backups**: pg_basebackup or wal-g for continuous WAL archiving to off-server storage.
3. **OpenBao snapshots**: nightly snapshot, encrypted, off-server.
4. **Test restoration** end-to-end. A backup you haven't restored from is not a backup.

### Phase E: Monitoring and alerting (1-2 days)

You're now responsible for the host. Configure:
- Disk full alert (>85%)
- CPU sustained high
- Memory pressure
- Postgres connection exhaustion
- Certificate expiry (<14 days)
- OpenBao seal status
- Wazuh agent health on the host itself

Route alerts to your phone (PagerDuty or a self-hosted alternative).

### Phase F: Cutover (1 day)

1. Final data sync from local (if you have meaningful data — usually you don't on local)
2. DNS cutover (your domain now points to the VPS)
3. Smoke test all flows: passkey login, app loads, observability sees events
4. Set up status page

---

## What stays the same

- All your Helm charts and K8s manifests (just value file overrides for new hostnames)
- The BFF code
- The backend services
- The frontend code
- The SpiceDB schema
- The OpenBao policies
- The Wazuh rules
- The Grafana dashboards
- The CLAUDE.md (with a note that we're now on VPS, not local)

About 80% of your work moves unchanged. The 20% that changes is substrate config.

---

## Operational considerations specific to single-VPS

### Single point of failure
Yes, you have one. Plan for it:
- DNS TTL low so failover is fast if you provision a backup server
- Backups frequent and tested
- Status page hosted elsewhere (so you can communicate during downtime)

### Maintenance windows
Hardware failures happen. Plan for ~99.5% uptime, not 99.99%. Communicate this to customers if applicable.

### Scaling
A single 16-vCPU / 64-GB server can handle thousands of authenticated users for an IAM platform comfortably. When you outgrow it, the migration is to either:
- Multi-node k3s cluster (still self-hosted)
- Managed cloud Kubernetes (jump to migration-to-aws.md)

### Compliance
A self-hosted VPS rarely satisfies SOC 2 / ISO 27001 auditors without significant additional documentation. If audit is a near-term need, skip VPS and go straight to AWS.

---

## Cost estimate (typical small SaaS)

| Item | Monthly |
|---|---|
| VPS (Hetzner CCX33) | $100 |
| Backup storage (Backblaze B2, ~500 GB) | $3 |
| Domain | $1 |
| Monitoring (PagerDuty Free or self-hosted) | $0-25 |
| **Total** | **~$105-130/month** |

vs. equivalent AWS deployment: $700-1500/month.

The trade-off is operational responsibility. You become your own SRE.

---

## When to graduate to cloud

Signals it's time to migrate to AWS / GCP / Azure:
- A customer asks for SOC 2 attestation
- You're spending >5 hours/week on infrastructure operations
- You need multi-region for any reason
- A single-server outage cost would exceed the cloud premium for several years
- You hire someone whose time on infra costs more than the cloud premium

When the time comes, see `migration-to-aws.md`.

---

## Resources

- [k3s docs](https://docs.k3s.io/)
- [Hetzner Cloud](https://www.hetzner.com/cloud)
- [Velero](https://velero.io/) for K8s backups
- [wal-g](https://github.com/wal-g/wal-g) for Postgres WAL archiving
- [Backblaze B2](https://www.backblaze.com/cloud-storage) for cheap durable storage
