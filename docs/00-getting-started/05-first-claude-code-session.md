# Your First Claude Code Session

Now that everything is installed, here's how the workflow actually goes. **Read this fully before starting Phase 0.**

---

## The mental model

Think of Claude Code as a senior engineer pair-programming with you. Your job is to:
1. Tell Claude Code which phase you're working on.
2. Paste the phase prompt from `docs/05-claude-code-prompts/`.
3. Watch what it does. Approve or stop.
4. Verify success criteria.
5. Move to the next phase.

You're the architect and the verifier. Claude Code is the implementer.

---

## Starting a session

In WSL2 Ubuntu:

```bash
cd ~/code/secforge-platform
claude
```

Claude Code starts in this directory. It automatically reads:
- The root `CLAUDE.md` (your project context)
- `.claude/settings.json` (your permission rules)
- Anything else in `.claude/` (custom commands)

So Claude Code already knows what kind of project this is, what stack you've chosen, and what's allowed.

---

## The phase workflow

### Step 1: Open the current phase document

In a separate VS Code window or in your terminal, open the prompt for the phase you're starting. They live in `docs/05-claude-code-prompts/phase-XX-<name>.md`.

Each phase document has the same structure:
1. **Status** — checkboxes you fill in as you progress.
2. **Prerequisites** — what must be true before starting.
3. **Goal** — one sentence describing what you'll build.
4. **What you (the human) need to do first** — manual steps Claude Code can't do (creating accounts, ordering hardware, etc.).
5. **Prompt for Claude Code** — the chunk of text you literally copy and paste.
6. **Success criteria** — how to verify it worked.
7. **Troubleshooting** — common issues.
8. **What's next** — the next phase.

### Step 2: Do the human prerequisites

Each phase has things only you can do (sign into AWS, register a domain, plug in a hardware key, accept a EULA). The phase document lists these. **Do them first.**

### Step 3: Paste the prompt into Claude Code

Copy the entire prompt block from the phase document and paste it into your Claude Code terminal session. Hit Enter.

Claude Code will:
- Confirm understanding.
- Often ask 1-3 clarifying questions before doing anything irreversible.
- Start executing.
- Show you commands it wants to run.

### Step 4: Approve commands judiciously

Claude Code will pause to ask permission for many commands (especially anything destructive or anything modifying cloud resources). Always read what it's about to do before approving.

If you see something that looks wrong, say "stop" or "no, wait." Claude Code will pause. You can ask it to explain or take a different approach.

**Never approve `kubectl delete namespace`, mass `kubectl apply -f`, or anything touching production-equivalent data without reading the diff/plan.** The settings file in `.claude/settings.json` already requires explicit confirmation for these. Even locally, deleting the wrong namespace can cost you 30 minutes to rebuild.

### Step 5: Run the success-criteria checks

After Claude Code says "Phase X complete," **don't just trust it.** Open the phase document and run each success criterion yourself. They're written as commands you copy and run. If any fail, tell Claude Code: "The check `kubectl get pods -n keycloak` shows nothing running. Fix this."

### Step 6: Update PLAN.md

Mark the phase as ✅ Complete and verified in PLAN.md. Have Claude Code do this:

```
> Update PLAN.md to mark Phase 3 as complete.
```

### Step 7: Take a break

Do not chain phases. Each phase is several hours of work and a major milestone. Stop, write a summary in your notes, do something else, come back fresh.

---

## When things go wrong

### You don't understand what Claude Code is doing

Ask:
```
> Explain what you're about to do and why, before running anything.
```

Or:
```
> I don't understand this command. What does `--cluster-issuer letsencrypt-prod` mean?
```

### Something failed and you're not sure how to fix it

Show Claude Code the error:
```
> When I ran `kubectl get pods`, I got: <paste the error>. What does this mean and what should we do?
```

### You suspect Claude Code is going down a wrong path

Stop it. Reset:
```
> Stop. Let's back up. The last working state was after we configured RDS. Re-read CLAUDE.md and the phase document, then propose a different approach.
```

### Claude Code is running long without progress

If a phase is taking dramatically longer than the document estimates (e.g., a 1-day phase has gone 3 days), something's off. Pause:
```
> We've been on this phase for much longer than expected. Summarize what we've done so far, what's remaining, and what's blocking us.
```

---

## Habits that make this work

1. **One phase at a time.** Don't jump ahead.
2. **Verify before celebrating.** Success criteria are the contract.
3. **Read what you're about to run.** Especially `terraform apply` and anything with `delete`.
4. **Keep notes.** A simple text file: "Phase 3 done on April 30 2026. Key decisions: chose X over Y because Z. Saw this weird thing that I'll watch for: [thing]."
5. **Ask before changing CLAUDE.md.** That file is the contract for the project. Changes ripple.
6. **Commit code at the end of every phase.** If something goes wrong, you can roll back.

---

## What Claude Code is NOT good at

- **Buying hardware.** You order the YubiKeys.
- **Deciding business questions.** "Should we accept this customer's contract?" — not Claude Code's job.
- **Managing your security.** You verify decisions; Claude Code implements them.
- **Knowing what it doesn't know.** If Claude Code is making something up, the success criteria should catch it. That's why we have them.

---

## Ready?

When you're ready to start Phase 0:

1. Make sure all prerequisites in [01-prerequisites.md](./01-prerequisites.md) are checked off.
2. Make sure your Docker Desktop K8s setup ([02-docker-desktop-setup.md](./02-docker-desktop-setup.md)) is complete.
3. Make sure your local DNS and TLS ([03-local-dns-and-tls.md](./03-local-dns-and-tls.md)) is working.
4. Open `docs/05-claude-code-prompts/phase-00-prerequisites.md`.
5. Start a Claude Code session in your project folder.
6. Paste the prompt from phase-00.

Off you go. Take your time.
