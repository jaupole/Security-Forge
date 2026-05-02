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
5. [Apps stuck in CrashLoopBackOff after a Docker Desktop restart](#5-apps-stuck-in-crashloopbackoff-after-a-docker-desktop-restart)
6. [Bootstrap kcadm-admin from scratch (the actual 5-step procedure)](#6-bootstrap-kcadm-admin-from-scratch-the-actual-5-step-procedure)

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

**App cleanup is automatic:** after the main OpenBao pods are Ready, the script also scans the `app` namespace for `CrashLoopBackOff` pods (apps that have been failing to bootstrap for the past 24h+) and deletes them so they restart with fresh SPIRE-issued SVIDs. Same automation as `unseal-seal.sh` step 3 — see Section 5 for the why.

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

## 5. Pods stuck in CrashLoopBackOff after a Docker Desktop restart

**When:** the cluster restarted, you ran the unseal procedure (Section 2), seal-pod is `1/1 Running`, but other pods are stuck in `CrashLoopBackOff`. Two flavors, both handled by the same root cause:

- **Main OpenBao** (`openbao-0/1/2`) — they tried to reach the seal-pod's Transit endpoint while it was still sealed, exited with code 1, kubelet kept restarting them with exponential backoff. Even after the seal-pod is healthy they're sitting on backoff timers.
- **Apps in the `app` namespace** (`helloworld-bff`, `authzen-facade`, etc.) — same pattern but at the app layer. Their SPIFFE-JWT-SVIDs (5-minute TTL) expired during the bootstrap-retry storm, so they keep presenting stale SVIDs to OpenBao and OpenBao keeps rejecting them.

**The procedure:**

Both flavors are now handled automatically by `unseal-seal.sh` (added 2026-05-01). After unseal verifies, the script:

1. Waits 15 seconds for main OpenBao to attempt auto-unseal on its own.
2. Scans `openbao` namespace for `openbao-0/1/2` pods in `CrashLoopBackOff` or `Error` state and deletes them so they restart against the now-unsealed seal-pod. Waits up to 90s for the deleted pods to reach Ready.
3. Scans `app` namespace for `CrashLoopBackOff` pods and deletes them so they restart with fresh SVIDs.

So in practice: just run the normal unseal (Section 2) and the cleanup happens automatically. You'll see `✓ deleted openbao-N (will restart against now-unsealed seal-pod)` and/or `✓ deleted helloworld-bff-... (will restart with fresh SVID)` in the script's output.

**Status note (2026-05-02):** the proper structural fix has landed — commit `f2e9c02` added a `wait-for-seal-unsealed` initContainer on the main OpenBao StatefulSet that polls `openbao-seal-0` and blocks pod startup until it reports unsealed (same pattern as the SPIFFE-CSI socket wait). Once your dev cluster has been helm-upgraded with that values.yaml, the main-OpenBao crashloop arm of this section becomes unreachable — the pods sit in `Init:0/2` phase instead, with no kubelet backoff. The app-namespace SVID-refresh sweep below remains useful belt-and-suspenders for the SPIRE-rotation race; it's not made obsolete by the initContainer.

**If you need to do it manually** (pods in some other namespace, or one of the auto-cleanups didn't catch it):

```bash
kubectl delete pod -n <namespace> <pod-name>
```

**Verification:** `kubectl get pods --all-namespaces | grep -v "Running\|Completed"` should be empty within ~60 seconds.

**If the script fails at "Main OpenBao pods didn't reach Ready in 90s":** that's a deeper issue than the routine backoff cycle (Raft state, NetworkPolicy, etc.). The script intentionally stops there rather than restart apps against a broken OpenBao. See `kubectl get pods -n openbao` and `kubectl logs -n openbao openbao-0 -c openbao --tail=30` for the actual error.

**See also:** the script lives at [`infrastructure/openbao/unseal-seal.sh`](../../infrastructure/openbao/unseal-seal.sh); the broader SPIFFE workload-identity model is in [`docs/01-architecture/02-workload-identity.md`](../01-architecture/02-workload-identity.md).

---

## 6. Bootstrap kcadm-admin from scratch (the actual 5-step procedure)

**When:** a fresh cluster (or one rebuilt after a Keycloak destroy-and-rebuild). Until `kcadm-admin` exists in the master realm with the right role grants, **none** of the kcadm-using provisioning scripts (`openbao.sh`, `grafana.sh`, `security-events.sh`, the realm bootstrap scripts) can run — they all source `_lib/kcadm-auth.sh` which authenticates as `kcadm-admin` against the master realm.

**What's happening:** chicken-and-egg. The provisioning script *needs* kcadm-admin to authenticate, but the client doesn't yet exist for the script to create. ADR-0022 § Bootstrap caveat documents this as "a one-time manual UI step" — that framing **understates** what's involved. The real procedure is **five UI clicks + one OpenBao write + eleven role grants** before the script can take over and self-bootstrap.

**The procedure (five steps, ~10 minutes, browser + one OpenBao write):**

1. **Create the client.** Open `https://auth-admin.secforge.local/admin/master/console/`. Realm: `master` → **Clients** → **Create client**.
   - Client ID: `kcadm-admin`
   - Client authentication: **ON**
   - Authorization: OFF
   - Standard flow: OFF · Direct access grants: OFF · Implicit flow: OFF
   - Service accounts roles: **ON**
   - Save.

2. **Copy the auto-generated secret.** Credentials tab → **Client secret** → copy.

3. **Write to OpenBao** (substitute the value from step 2):

   ```bash
   kubectl exec -n openbao openbao-0 -c openbao -- \
       env BAO_SKIP_VERIFY=1 BAO_TOKEN=$ROOT_TOKEN \
       bao kv put secret/keycloak/clients/kcadm-admin \
           client_secret='THE-COPIED-SECRET-VALUE'
   ```

4. **Apply 11 role grants from the master-realm UI** (this is the long part). For each grant: in the master realm → **Users** → search `service-account-kcadm-admin` → click → **Role mappings** tab → **Assign role** → **Filter by clients** → select. The 11 grants are:

   | Realm-management client | Roles to grant |
   |---|---|
   | `master-realm` | `manage-clients`, `manage-users` (2) |
   | `platform-realm` | `manage-clients`, `manage-realm`, `manage-users`, `view-realm` (4) |
   | `secforge-tenants-realm` | `manage-clients`, `manage-users`, `view-realm`, `view-authorization`, `view-events` (5) |

   Each role must be the **client role** of the named realm-management client (not a realm-level role, not a master-realm composite). 11 roles total across 3 clients.

5. **Run the self-bootstrap.** With `BAO_TOKEN` set to a token with read on `secret/data/keycloak/clients/kcadm-admin`:

   ```bash
   BAO_TOKEN=$(cat ~/.bao-token) bash infrastructure/keycloak/clients/kcadm-admin.sh
   ```

   The script reads the secret you just wrote, authenticates kcadm as `kcadm-admin`, and reconciles the role grants from ADR-0022's "Roles granted" table (idempotent — if a grant is already in place from step 4, kcadm reports it as present and moves on). After this, every other kcadm-using script just works.

**Verification:** the next provisioning script you run finishes without "kcadm auth failed" or "user lacks permission" — for example `BAO_TOKEN=$(cat ~/.bao-token) bash infrastructure/keycloak/clients/security-events.sh` returns "auth ok" and creates its clients clean.

**If it didn't work:**
- "kcadm auth failed" → step 3 wrote the wrong secret, or the kcadm-admin client in step 1 has Service-accounts-roles OFF (re-check the toggle in the UI).
- "user lacks permission to manage clients in `<realm>`" → step 4 missed a role; re-open the Users → service-account-kcadm-admin → Role mappings page and check the realm-management client's listed roles against the table above.
- Step 5's `kcadm-admin.sh` exits with "OpenBao read returned empty" → BAO_TOKEN doesn't have read capability on the path; re-mint with `bao token create -policy=admin` (5 min ttl is fine).

**See also:** [ADR-0022](../02-decisions/0022-kcadm-admin-service-account.md) (the architectural rationale), [`infrastructure/keycloak/clients/kcadm-admin.sh`](../../infrastructure/keycloak/clients/kcadm-admin.sh) (script header reproduces these steps), [`infrastructure/keycloak/_lib/kcadm-auth.sh`](../../infrastructure/keycloak/_lib/kcadm-auth.sh) (the shared fetch+auth helper every consumer script uses). The ADR text itself is being updated to match this 5-step reality — see operator-backlog #11.

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
