# SecForge Platform

A secure, open-source Identity and Access Management (IAM) platform that runs on a single public Hetzner bare-metal k3s node serving `*.secforge.dev`. Build the platform once and develop your three applications (Proposal Forge, Project Tracker, future PM app) against it, with a clean path to managed cloud when you're ready.

## What this repository contains

This is the SecForge platform: a complete IAM stack — Keycloak, SpiceDB, OpenBao, SPIRE, Istio, Teleport, Wazuh, the BFF pattern — running on a single public Hetzner bare-metal k3s node. Everything you build here is portable: when you eventually move to AWS or another host, the application code, Helm charts, schemas, and policies all move with you. Only the substrate changes.

## Why a single self-hosted node

You're at the stage where you're iterating on three applications and discovering the patterns. A single Hetzner bare-metal node gives you real DNS, real TLS, and real public traffic at a fraction of the cost and complexity of a managed cloud control plane. You can rebuild the cluster on the node quickly when needed. When the apps stabilize and you need managed-cloud realism (multi-AZ, managed backups, autoscaling), you migrate.

## Where to start (read in this order)

1. **[PLAN.md](./PLAN.md)** — the master plan with phases and where you are in it
2. **[docs/00-getting-started/00-glossary.md](./docs/00-getting-started/00-glossary.md)** — every technical term used, defined plainly
3. **[docs/00-getting-started/01-prerequisites.md](./docs/00-getting-started/01-prerequisites.md)** — what to install on your computer
4. **[docs/00-getting-started/02-docker-desktop-setup.md](./docs/00-getting-started/02-docker-desktop-setup.md)** — k3s node configuration
5. **[docs/00-getting-started/03-local-dns-and-tls.md](./docs/00-getting-started/03-local-dns-and-tls.md)** — `*.secforge.dev` public DNS and Let's Encrypt TLS
6. **[docs/00-getting-started/05-first-claude-code-session.md](./docs/00-getting-started/05-first-claude-code-session.md)** — how to use Claude Code
7. **[docs/05-claude-code-prompts/README.md](./docs/05-claude-code-prompts/README.md)** — phase-by-phase prompts to paste into Claude Code

## What "done" looks like

After ~4-6 weeks of part-time work (faster than the AWS edition because no managed-cloud control-plane setup), you'll have:

- A complete IAM platform running on a public Hetzner bare-metal k3s node
- A working "Hello World" app demonstrating the full passkey → BFF → backend → SpiceDB → response flow
- Three application skeletons (Proposal Forge, Project Tracker, future PM app) ready to develop against
- Clean migration boundaries so you can move to managed cloud later without re-architecting

## Resource expectations on your 32 GB machine

| Phase | RAM in use | CPU |
|---|---|---|
| Just the platform (Phases 1–8) | ~8–10 GB | 2–4 cores during steady state |
| Platform + Hello World (Phase 9) | ~10 GB | same |
| Platform + 3 dev apps actively running | ~14–18 GB | 4–6 cores |

That leaves you 14+ GB headroom for VS Code, browser, etc. on a 32 GB machine. No problem.

## When you eventually move to managed cloud

Two paths are documented for "what changes":
- **To another single VPS / homelab server** (still self-hosted): see `docs/06-reference/migration-to-vps.md`
- **To AWS** (managed cloud): see `docs/06-reference/migration-to-aws.md` — most of the AWS-Edition phase prompts become applicable

The platform itself doesn't change in either case. Only the substrate.

## License

Your private platform code. Apply your chosen license. Third-party components (Keycloak, SpiceDB, OpenBao, etc.) retain their open-source licenses.
