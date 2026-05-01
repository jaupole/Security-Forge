# Claude model selection — when to use Opus, Sonnet, Haiku

> **Audience:** any Claude Code instance (Windows VS Code, WSL terminal) working on SecForge, plus the human operator. The goal is to spend Opus tokens where they earn their cost and drop to cheaper models everywhere else, without sacrificing security quality.

---

## The rule of thumb

> If the task is **"decide *whether* to do X,"** use Opus.
> If the task is **"do X and tell me what happened,"** use Sonnet.
> If the task is **"is X true right now?"**, use Haiku.

That single sentence resolves >90% of model-choice questions on this project.

---

## Three-tier framework

### Opus — design, security reasoning, synthesis

Use Opus when a wrong answer has multi-day consequences or breaks a security invariant.

- ADR drafting (any decision in `docs/02-decisions/`)
- Architecture document changes
- Audit / review work (the four-agent Fix-after-07 audit was an example — but the *synthesis* was Opus, the agents themselves should have been Sonnet)
- Threat model writing (Section F of `Fix after 07/01-fix-prompt.md`)
- App refactors that touch a security boundary — `apps/lib/oidc/`, `apps/lib/secrets/`, `apps/lib/authzn/` interface design
- Resolving the four open ADR-0012 design questions
- Novel debugging where the failure mode is genuinely unclear (e.g., the `realm_access.roles` plumbing investigation — three candidate root causes, multi-system)
- Designing AuthorizationPolicy ALLOWs (each one is an explicit trust decision)
- Writing or expanding the threat model
- Compliance-cutover impact analysis (will this change force app rewrites?)

### Sonnet 4.6 — routine execution, doc edits, mechanical work

Use Sonnet when the *what to do* is decided and you're executing it.

- Routine Helm value tweaks, YAML edits to existing manifests
- Running `helm upgrade` / `kubectl apply` and reporting status
- PLAN.md status flag flips (✅ → ⬜, status block updates)
- Adding navigation headers to phase docs
- Git commits + commit messages
- Documenting work just done (runbook write-ups *after* the work, not the design before)
- Refactors that are mechanical (rename a variable, extract a function with no judgment calls)
- "Apply this manifest and watch until Ready, report when done"
- Mass file edits where the change is the same in each file
- Verification scripts: "run these 8 kubectl commands, summarize"
- Boilerplate generation (Go struct skeletons, YAML scaffolds)

### Haiku 4.5 — pure status / lookup / tool-use

Use Haiku when you don't need the model to think, only to wire calls.

- "Is the cluster healthy?" — `kubectl get pods -A` and report any non-Running
- "Where is X defined?" — grep + return location
- "Does this file contain Y?" — read + boolean answer
- One-shot kubectl status checks
- File-tree listings, "what files are in `infrastructure/openbao/`?"
- Slash-command-style scripted ops (`/health-check`, `/reset-cluster`)
- "Read this log, find any line containing ERROR"

---

## Anti-patterns (cost spent for no benefit)

- **Opus running parallel `Explore` subagents that just read files and report.** Spawn Explore subagents on Sonnet (or Haiku for the simplest reads); keep Opus for synthesis only. Pass `model: "sonnet"` to the Agent tool.
- **Opus for PLAN.md status updates.** Pure doc editing. Sonnet handles it identically.
- **Opus for "apply this kubectl manifest and watch for Ready."** Tool-use loop, no reasoning. Drop to Sonnet or Haiku.
- **Sonnet for ADR drafting.** Subtle long-term consequences; the cost saving is dwarfed by the risk of a wrong call that lives in the codebase forever.
- **Sonnet for designing AuthorizationPolicy rules.** Each ALLOW is a trust decision. Opus.

---

## How to switch models

### Inline in Claude Code (both VS Code and WSL)
- `/model sonnet` — switches current session to Sonnet 4.6
- `/model opus` — switches back to Opus 4.7
- `/model haiku` — switches to Haiku 4.5

Switch *before* a stretch of routine work, then switch back before the next design decision.

### Per-subagent
When spawning an Agent (via the Agent tool), pass `model: "sonnet"` or `model: "haiku"` explicitly. Default inherits from the parent — which means an Opus parent gets Opus subagents unless told otherwise. This is the single biggest lever on this project; the Fix-after-07 audit alone could have saved meaningful tokens by spawning the four Explore agents on Sonnet.

### Project default
The default model for a Claude Code session is set in `.claude/settings.json` or `~/.claude/settings.json`. Recommended for SecForge:
- **VS Code instance** (mostly design / audit / synthesis): default **Opus**, drop to Sonnet manually for routine sweeps.
- **WSL instance** (mostly execution / kubectl / Helm / file edits): default **Sonnet**, escalate to Opus manually when a real design question appears.

This is a recommendation, not auto-applied. Change via the `update-config` skill or by editing settings.json directly.

---

## Friction-free escalation rule

A Claude on Sonnet that hits a question whose answer would land in an ADR, threat model, or security-invariant boundary should **stop and ask the human to switch to Opus** rather than answering on Sonnet. Better to pay the model-switch latency than to bake a Sonnet-quality decision into a long-lived document.

The reverse is also true: a Claude on Opus that finds itself doing a 30-minute YAML edit should suggest dropping to Sonnet for the duration.

---

## Cost calibration (rough orders of magnitude)

- Sonnet ≈ 1/5 the cost of Opus per token
- Haiku ≈ 1/5 the cost of Sonnet per token (≈ 1/25 of Opus)

These ratios make the rubric concrete: if you spend a session 50% on routine work and 50% on design, dropping the routine half to Sonnet cuts your bill by ~40%. Dropping a third of that to Haiku cuts another ~5%. That's the realistic ceiling.
