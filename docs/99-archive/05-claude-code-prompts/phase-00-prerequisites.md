> 🗄️ **ARCHIVED 2026-06-07 — local-first / build-era document.**
> This describes the original Docker Desktop / WSL2 / `secforge.local` build, **not** the current
> bare-metal `secforge-prod` deployment. Kept for history only. For current state see `PLAN.md`,
> `docs/01-architecture/`, and `docs/06-reference/operator-backlog.md` (archive index: `docs/99-archive/README.md`).

# Phase 0 — Prerequisites Verification (Local)

> **Navigation:** (start of chain) · [Next: Phase 1 — Foundation](./phase-01-foundation.md) ➡ · [📋 PLAN.md](../../PLAN.md) · [Phase prompts index](./README.md)
>
> **Depends on (must be ✅):** (none — first phase)
> **Blocks:** every subsequent phase
>
> **Status (mirrors PLAN.md, last updated 2026-05-01):** ✅ Complete (2026-04-28).
>
> PLAN.md is the source of truth for phase status. If this block diverges from PLAN.md's quick-ref table, **PLAN.md wins**; update this block in the same edit that bumps PLAN.md.

**Estimated time:** 1 hour

**Prerequisites:** Everything in `docs/00-getting-started/` is complete.

---

## Goal of this phase

Confirm with Claude Code that your local toolchain, Docker Desktop K8s, mkcert CA, and hosts file resolution are all working. Catch setup errors before you start deploying components.

---

## What you (the human) need to do first

1. ✅ Complete every doc in `docs/00-getting-started/` (01-prerequisites, 02-docker-desktop-setup, 03-local-dns-and-tls).
2. ✅ Open Claude Code in this project: `cd ~/code/secforge-platform-local && claude`.

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code.

---

```
We're starting Phase 0 of the SecForge Local Edition platform build. Read CLAUDE.md, PLAN.md, and docs/05-claude-code-prompts/phase-00-prerequisites.md before doing anything.

Your task is to verify that my local toolchain, Docker Desktop Kubernetes, mkcert CA, and hosts file resolution are correctly set up. Do NOT deploy any platform components yet — this phase is verification only.

Run these checks in order. For each, run the command and report ✅ or ❌. If ❌, propose the fix but do not apply it without my approval.

## Local tools

1. `docker --version` — should show Docker 27+
2. `kubectl version --client` — Client v1.31+
3. `helm version` — v3.16+
4. `k9s version` — 0.32+
5. `yq --version` — v4+
6. `cosign version` — v2.4+
7. `mkcert -version` — v1.4+
8. `stern --version` — 1.30+
9. `grpcurl --version` — v1.9+
10. Git config: `git config --global user.name` and `git config --global user.email`

## Docker Desktop & cluster

1. `docker ps` — verify Docker daemon is responsive
2. `kubectl config current-context` — should output `docker-desktop`
3. `kubectl get nodes` — should show one node, Ready, with reasonable allocatable memory (>10 GB) and CPU (>4)
4. `kubectl get pods -n kube-system` — system pods are all Running
5. `kubectl get storageclass` — should have a default storage class (usually `hostpath`)

## DNS resolution

1. `getent hosts auth.secforge.local` — should return `127.0.0.1   auth.secforge.local`
2. `getent hosts app.secforge.local` — same
3. From Windows side, ask me to run `ping app.secforge.local` and paste the output. Verify it resolves to 127.0.0.1.

## TLS / mkcert

1. `mkcert -CAROOT` — find the CA path
2. Verify the CA cert exists: `ls -la $(mkcert -CAROOT)/rootCA.pem`
3. Verify mkcert CA is in the local trust store. From WSL2:
   - `curl -fsS https://api.github.com/ -o /dev/null && echo OK` (sanity check)
   - Check if there's a wildcard cert for *.secforge.local in `~/.local/secforge-certs/`. If not, ask me to run the mkcert command from `docs/00-getting-started/03-local-dns-and-tls.md`
4. Ask me to verify the mkcert CA is also in the Windows trust store (from `certmgr.msc` → Trusted Root Certification Authorities). I'll confirm.

## Project structure

1. `CLAUDE.md` exists at project root and is readable
2. `PLAN.md` exists and is readable
3. The phase directory structure exists
4. `.claude/settings.json` is valid JSON

## Output

Produce a summary:
- Number of ✅ checks
- Number of ❌ checks
- For each ❌, what it is and what we should do about it
- Either: "Phase 0 complete, ready for Phase 1" OR "Phase 0 has N issues to resolve"

Do NOT update PLAN.md until I confirm everything is good. Do not deploy any components.
```

---

## Success criteria

- [ ] All local tools verified
- [ ] Docker Desktop K8s context active and node Ready
- [ ] mkcert CA installed in WSL2 + Windows trust stores
- [ ] Wildcard cert for `*.secforge.local` exists
- [ ] hosts file entries resolve from both Windows and WSL2
- [ ] Project files all readable
- [ ] PLAN.md updated to mark Phase 0 ✅

---

## Troubleshooting

### "kubectl context is something else, not docker-desktop"
Switch: `kubectl config use-context docker-desktop`. If `docker-desktop` isn't in the list, Kubernetes isn't enabled in Docker Desktop yet — go to Settings → Kubernetes and enable.

### "kubectl get nodes shows the node as NotReady"
Likely Docker Desktop is still starting K8s. Wait 2-3 minutes. If it persists, restart Docker Desktop. If it still fails, Settings → Kubernetes → "Reset Kubernetes Cluster" (nuclear option).

### "ping app.secforge.local doesn't resolve from Windows but works from WSL2"
Windows hosts file edit didn't save. Open Notepad as Administrator, edit `C:\Windows\System32\drivers\etc\hosts` again. Or vice versa.

### "Browser shows certificate warning on https://example.localhost"
The mkcert CA isn't in the Windows trust store. Re-run the install steps from `03-local-dns-and-tls.md` Section 1.

---

## What's next

[Phase 1 — Foundation](./phase-01-foundation.md). This is where you start deploying things.
