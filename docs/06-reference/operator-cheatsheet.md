# Operator Cheatsheet — Jason's Personal Reference

> **This document is for Jason (the project owner) — plain-English answers to the operational questions he tends to come back to.** It's intentionally NOT authoritative project documentation; the canonical runbooks live in [`docs/03-runbooks/`](../03-runbooks/) and the architecture docs in [`docs/01-architecture/`](../01-architecture/). When this cheatsheet conflicts with a runbook, the runbook wins. Use this for "I just want to know what to do, not why" — use the runbooks for "I need to understand the full picture."
>
> **For Claude (any session):** when Jason asks an operational question that's likely to come back (he says "I always forget X" or asks the same thing in a future session), offer to add a section here so it's captured for next time. Section template at the bottom.

---

## Table of Contents

1. [Cold-start the cluster after a Docker Desktop reboot](#1-cold-start-the-cluster-after-a-docker-desktop-reboot)
2. [Unseal OpenBao — routine case](#2-unseal-openbao--routine-case)
3. [Unseal OpenBao — after a multi-day pause (the gotcha case)](#3-unseal-openbao--after-a-multi-day-pause-the-gotcha-case)
4. [Where the unseal keys live](#4-where-the-unseal-keys-live)

---

## 1. Cold-start the cluster after a Docker Desktop reboot

**When:** every time Docker Desktop restarts (intentional reboot, Windows update, laptop sleep that crashes the WSL VM, etc.).

**What's happening:** Docker Desktop's K8s VM comes up; all your pods restart. Most things auto-recover. Two pieces need your attention:

1. **OpenBao seal-pod** (`openbao-seal-0`) comes up sealed and stays sealed until you unseal it manually with your Shamir keys. The main OpenBao (`openbao-0/1/2`) waits on the seal-pod.
2. **All other pods** auto-restart and re-attach to their persistent storage. Nothing for you to do.

**The procedure:**

1. Wait ~30-60 seconds for Docker Desktop to settle.
2. Check the platform status: `kubectl get pods --all-namespaces | grep -v Running` — anything not Running yet is still starting up; the OpenBao pods will show in this list because they're sealed.
3. Run the unseal procedure (Section 2 below).
4. Verify everything is back: `kubectl get pods --all-namespaces | grep -v "Running\|Completed"` should return nothing.

If it's been more than 24 hours since the cluster was last running, see Section 3 — there's a known multi-day-pause gotcha you'll hit.

---

## 2. Unseal OpenBao — routine case

**When:** the cluster cold-started less than 24 hours ago. The most common case.

**What you're doing:** you're providing 3 of 5 Shamir secret-shares to the seal-pod (`openbao-seal-0`). Once it has 3 valid shares, it unseals itself, and the main OpenBao (`openbao-0/1/2`) auto-unseals via the Transit endpoint within ~10 seconds.

**The command (one-liner from your WSL shell, in the project root):**

```bash
bash infrastructure/openbao/unseal-seal.sh
```

**What happens when you run it:**
- The script prompts you for an unseal key, no echo (you paste, press Enter, nothing shows).
- Repeat 2 more times (3 keys total — any 3 of your 5).
- Script reports "Unsealed."
- Wait ~10 seconds.
- Run `kubectl get pods -n openbao` — all 4 pods should be `1/1 Running` (openbao-0, openbao-1, openbao-2, openbao-seal-0).

**If it didn't take:**
- You probably typed one of the keys wrong, or entered the same key twice. Re-run the script with 3 fresh distinct keys.
- The script wipes the keys from its memory the moment it's done — they're never written to disk or logged.

---

## 3. Unseal OpenBao — after a multi-day pause (the gotcha case)

**When:** the cluster has been off for more than ~24 hours (long weekend, vacation, etc.).

**What's different:** the Transit unseal token used by the main OpenBao to talk to the seal-pod has a 24-hour TTL. It auto-renews while the cluster is up, but if the cluster was down longer than 24 hours, the token expired and didn't get renewed. So even after Section 2's unseal procedure, the main OpenBao will stay sealed.

**Symptom:** you ran `unseal-seal.sh`, the seal-pod shows `1/1 Running`, but `openbao-0/1/2` are still in a `0/1 Running` or `CrashLoopBackOff` state. The main OpenBao logs show `403 permission denied` (NOT `503 Vault is sealed` — that's the routine case in Section 2).

**The recovery — one command:**

```bash
bash infrastructure/openbao/rotate-transit-token.sh
```

Prompts you for the **seal-OpenBao initial root token** (NOT the 5 unseal keys, NOT the main OpenBao root — the seal-OpenBao's own root from your offline password manager; not echoed back, wiped from memory after use). Then it does the full mint-fresh-token → patch `openbao-transit-token` Secret → run `apply-main.sh` → roll `openbao-2 → 1 → 0` → `kubectl wait --for=condition=Ready` sequence in one go and exits 0 when all three pods are `1/1 Running` (or non-zero with diagnostic hints if the wait times out at 180s).

The script absorbs the 2026-05-01 gotcha: if `apply-main.sh` "bails" with a too-many-restarts watchdog message on openbao-0, the seal block has already been re-rendered before the watchdog fires; the script proceeds to the pod roll which is what completes recovery.

**Source of truth:** `docs/03-runbooks/openbao-recovery.md § "Rotate the Transit unseal token"` (the manual 4-step procedure is preserved there for troubleshooting individual stages).

**Heads-up:** this is the same situation that's tracked as **operator-backlog #4** (Phase 7d will codify a permanent TTL strategy fix so this doesn't keep biting). Until then, the script is the recipe. Strong argument for accelerating operator-backlog #10's quarterly rotation cadence — once cron-driven, a >24h cold cluster wouldn't trip the TTL.

---

## 4. Where the unseal keys live

**Your 5 Shamir unseal keys + the initial root token + the original Transit token** were printed exactly once during Phase 5.2's `init-seal.sh`. They are in your offline password manager.

They are NOT:
- In any K8s Secret
- In any ConfigMap
- In any committed file in this repo (`.gitignore` blocks `**/shamir-keys/`, `**/unseal-keys.txt`, `**/recovery-key*`, `**/openbao-init-output*`)
- In any backup that touches the cluster

**If you lose them:** there is no recovery for the seal-pod. The OpenBao runbook ([`openbao-seal-unseal.md` lines 47-63](../03-runbooks/openbao-seal-unseal.md)) documents the "destroy and rebuild" path, which loses ALL OpenBao state (every secret, every policy, every auth method config). You'd be re-running Phase 5.4-5.10 from scratch. **Do not lose the keys.**

The 5 recovery keys for the *main* OpenBao (the 5/3 set you saw in `bao status`) are a SEPARATE set — they let you mint a fresh root token on an *already-unsealed* main OpenBao. They don't help you unseal the seal-pod.

---

## Section template (for adding new entries — Claude or Jason)

```markdown
## N. Short title (the question you'd type into Google)

**When:** the trigger / scenario where you'd reach for this section.

**What's happening:** 1-2 sentences of plain-English context — what's broken or what state the system is in.

**The procedure:**
1. Step one in plain English.
2. Step two.
3. (Commands welcome — operator can run shell + browser fine; just don't make them read code to understand what's happening.)

**Verification:** how you know it worked.

**If it didn't work:** the most common failure mode and what to try.

**See also:** link to the canonical runbook / ADR for the full picture.
```
