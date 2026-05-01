# ADR-0021: Git initialization and commit-signing strategy

**Status:** In progress (stub — slot reserved 2026-05-01)
**Date:** TBD (operator session — pre-Fix-after-07 and pre-Phase-9)
**Decision-makers:** Project owner

## Context

The SecForge project has been built across seven phases (Phase 0 → Phase 7) with **zero version control**. Discovered 2026-05-01 during Phase 6b-1 documentation work, when wsl Claude tried to execute the `git checkout -b fix-after-07` step from `Fix after 07/01-fix-prompt.md` and `git rev-parse --is-inside-work-tree` returned `fatal: not a git repository`.

The project lives at `/mnt/c/Users/jaupo/Projects/Security Forge/` (Windows host, accessed from WSL2 via `/mnt/c`). No `.git` directory anywhere in the tree. No commit history. No branch model. No remote.

## Why this matters

1. **No rollback path.** Any Claude Code session (Windows VS Code, WSL terminal) is one bad edit away from destroying work that exists nowhere else. Backups are "whatever's on disk."
2. **`Fix after 07/01-fix-prompt.md` is structurally git-dependent.** Its §0.3 creates a branch; every section ends with `git commit`; rollback advice cites `git revert`. None of that runs without git.
3. **Phase 9+ cannot proceed.** Building real apps without source control is a non-starter — no review, no provenance, no rollback.
4. **Compliance posture.** Image-signing pipelines (Cosign), SBOM generation, supply-chain attestations all expect commit hashes as inputs. Threat model needs to document "how do you know the cluster matches what's in source" — without git, that answer is "we don't track it."
5. **Multi-Claude coordination.** Two Claude instances (VS Code + WSL) edit this codebase. Without commits, there's no concurrency story — just last-writer-wins on whatever each session happens to touch.

## Decision (to be filled in)

This stub reserves the ADR slot. The decision session covers:

### 1. `.gitignore` contents

Must exclude (NON-NEGOTIABLE):
- Shamir unseal keys (any path)
- OpenBao recovery PEMs / root tokens / Transit tokens
- `infrastructure/mkcert/` private keys
- `.claude/settings.local.json` (per-machine settings; not per-project state)
- Any `*.key`, `*.pem`, `*.crt` outside `infrastructure/<component>/certificates/` (and even there, only if the cert lifecycle is meant to be reviewed)
- Generated artifacts: `/tmp/*-debug.log`, build outputs

Should exclude (defaults to yes unless operator says otherwise):
- `notes/` (operator scratchpad; loki-baseline diagnostics, etc.)
- Helm-vendored chart artifacts that can be re-pulled (e.g., `infrastructure/wazuh/vendor/wazuh/charts/*.tgz`)

Must INCLUDE:
- All ADRs, runbooks, architecture docs
- All YAML manifests, Helm values, Kustomize overlays
- All apply scripts and verification scripts
- The vendored Wazuh chart source (we own the maintenance burden — keep it in tree)
- `Fix after 07/` directory and all contents
- All app code (`apps/helloworld-bff/`, `apps/authzen-facade/`)

### 2. Commit author identity

`git config user.name` and `user.email`. The user's email per auto-memory is `jaupole@googlemail.com`. Confirm.

### 3. GPG / SSH commit signing

Strong recommendation: **enable signed commits from day one.** The user is a security specialist building a security platform; verifiable commit provenance is foundational. Choices:

- **GPG signing** (traditional, requires key management)
- **SSH signing** (`gpg.format = ssh`, simpler — uses existing SSH keys; supported by GitHub since 2023)

SSH signing is the pragmatic local-edition choice: lower setup cost, works with existing keys, GitHub verifies it natively if the project ever pushes to a remote.

### 4. Initial commit strategy

Two real options:

- **(a) Single big "initial state 2026-05-XX" commit.** Everything currently on disk becomes the first commit. No phase-by-phase history. Pros: one decision, fast. Cons: future-you has no `git log` story for "when did we add SPIRE?"
- **(b) Backfilled phase-by-phase history.** Use PLAN.md's status dates to construct a synthetic history (Phase 0 commit → Phase 1 commit → ... → Phase 7 commit). Each commit captures roughly what landed in that phase. Pros: clean log; future archeology works. Cons: requires manual reconstruction; dates and authorship are synthetic, which is itself a documentation issue.

**Default recommendation: (a) single initial commit.** Synthetic history is honest only if labeled as such, and the value of `git log` for archeology is dwarfed by what PLAN.md and the ADRs already record. Future commits start the real history.

### 5. Remote

Three options:
- **Private GitHub repo** — most flexibility; integrates with future Cosign keyless signing (GitHub OIDC); standard for the security/dev community.
- **Self-hosted Gitea** — full sovereignty; no external dependency; matches the local-edition / cloud-migration story (could run on the same Postgres operator).
- **Local-only** — no remote yet. Defensible until Phase 9 ramps multi-developer collaboration.

For a single-developer local-edition platform with cloud aspirations, **start local-only and decide on remote at Phase 9 / cloud-migration time** is reasonable. But if any thought of collaboration exists, push to a remote sooner — `git` without backups is barely better than no `git`.

### 6. Pre-commit hooks

The project's own `templates/app-repo/.pre-commit-config.yaml` already references the right pattern (per Fix-after-07 audit findings). Apply the same to the project root:
- **gitleaks** — secret detection (catches accidentally-committed credentials)
- **block-env-files** — refuses any `.env` or `.envrc`
- **block-secret-shaped-vars** — refuses things like `*_PASSWORD =`, PEM key block headers (the `BEGIN ... KEY` family), etc.
- **trailing-whitespace** + **end-of-file-fixer** — hygiene

These prevent the project from ever getting into the state where a Shamir key was almost committed.

## Out of scope of this ADR

- Branch protection rules (decide if/when remote is set up)
- Code review process (decide at Phase 9 when multi-actor edits become routine)
- CI/CD wiring (separate phase)
- Image-signing key custody (already a separate gap — see F-ADR-12 in Fix-after-07 audit)

## Sequencing

This decision MUST land **before**:
- `Fix after 07/01-fix-prompt.md` runs (it depends on git)
- Phase 9 (cannot build apps without source control)
- Phase 7c PeerAuthentication STRICT cutover (rollback needs git)

Can land in parallel with: Phase 7d, Phase 6b-1 documentation work (current session is using Option B — file edits without commits).

## Consequences

**Commits us to:**
- All future Claude sessions can use git operations (branches, commits, reverts, diffs)
- A safety net for destructive edits
- Foundation for Phase 9+ multi-actor development

**Preserves:**
- Existing file structure (no path changes required)
- All current ADRs, runbooks, manifests

**New risks:**
- Initial commit captures any latent secret-shaped content. **Run gitleaks against the working tree BEFORE the first commit, not as a pre-commit hook for the first commit itself.** If gitleaks flags anything, fix it before initialization.
- WSL filesystem on `/mnt/c` has known git performance issues for very large repos. Not a concern at current size; flag for revisit at Phase 10+.

## References

- Discovered: 2026-05-01, Phase 6b-1 documentation work, wsl Claude session
- Triggered by: `git checkout -b fix-after-07` step in `Fix after 07/01-fix-prompt.md` §0.3
- Related: F-ADR-12 in `Fix after 07/00-audit-findings.md` (image-signing key custody — partially overlaps; both touch supply-chain provenance)
- CLAUDE.md "Git Safety Protocol" section — assumes git exists; needs no change once this ADR lands
