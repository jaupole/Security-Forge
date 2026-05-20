# ADR-0021: Git initialization and commit-signing strategy

**Status:** Accepted
**Date:** 2026-05-01
**Decision-makers:** Project owner
**Initial commit:** `10c6a06` (ed25519-signed; verify with `git log --show-signature -1 10c6a06`)

## Context

The SecForge project has been built across seven phases (Phase 0 → Phase 7) with **zero version control**. Discovered 2026-05-01 during Phase 6b-1 documentation work, when wsl Claude tried to execute the `git checkout -b fix-after-07` step from `Fix after 07/01-fix-prompt.md` and `git rev-parse --is-inside-work-tree` returned `fatal: not a git repository`.

The project lives at `/mnt/c/Users/jaupo/Projects/Security Forge/` (Windows host, accessed from WSL2 via `/mnt/c`). No `.git` directory anywhere in the tree. No commit history. No branch model. No remote.

## Why this matters

1. **No rollback path.** Any Claude Code session (Windows VS Code, WSL terminal) is one bad edit away from destroying work that exists nowhere else. Backups are "whatever's on disk."
2. **`Fix after 07/01-fix-prompt.md` is structurally git-dependent.** Its §0.3 creates a branch; every section ends with `git commit`; rollback advice cites `git revert`. None of that runs without git.
3. **Phase 9+ cannot proceed.** Building real apps without source control is a non-starter — no review, no provenance, no rollback.
4. **Compliance posture.** Image-signing pipelines (Cosign), SBOM generation, supply-chain attestations all expect commit hashes as inputs. Threat model needs to document "how do you know the cluster matches what's in source" — without git, that answer is "we don't track it."
5. **Multi-Claude coordination.** Two Claude instances (VS Code + WSL) edit this codebase. Without commits, there's no concurrency story — just last-writer-wins on whatever each session happens to touch.

## Decision

The decisions below were made in a 2026-05-01 operator session. The original stub framing for each section is preserved for context; the resolved choice is recorded under "**Decided:**".

### 1. `.gitignore` contents

**Decided:** see [`.gitignore`](../../.gitignore) at project root, committed in `10c6a06`. Categories:

- **Secrets (non-negotiable):** Shamir unseal keys, OpenBao recovery PEMs, root tokens, Transit tokens, mkcert CA private keys, generic `*.key`/`*.pem`/`*.p12`/`*.pfx`/`*.jks` outside known-good paths, `.env*` (except `.env.example`)
- **Per-machine state:** `.claude/settings.local.json`, `.claude/projects/`, `.vscode/`, `.idea/`, OS files (`.DS_Store`, `Thumbs.db`), editor swap files
- **Build artifacts:** Go binaries (`apps/helloworld-bff/helloworld-bff`, `apps/authzen-facade/authzen-facade`), `*.test`, `*.out`, `coverage.txt`
- **Vendored Helm tarballs:** `platform/manifests/wazuh/vendor-chart/charts/*.tgz` (the unpacked chart source IS committed; the tarballs that can be re-pulled are not)
- **Operator scratchpad:** `notes/` (loki-baseline diagnostics, etc.)
- **Logs and temp:** `*.log` (with carve-outs for docs), `*.tmp`, `/tmp/`
- **Kubectl dumps and debug outputs:** `kubectl-dump-*.yaml`, `*-debug.log`, `*-baseline-*`

Notably **kept in tree** (per .gitignore comments):
- All ADRs, runbooks, architecture docs
- All YAML manifests, Helm values, Kustomize overlays
- All apply scripts and verification scripts
- The vendored Wazuh chart source (we own the maintenance burden)
- `apps/*/sbom/*` (signed audit artifacts)
- `Fix after 07/` directory and contents

### 2. Commit author identity

**Decided:** `Jason Upole <jaupole@gmail.com>`. Aligned with the operator's pre-existing global git config (rather than the previously-noted `googlemail.com` form, which is functionally an alias but split commit identity unnecessarily). Configured at the repo level via `git config --unset user.email` to fall through to the global identity.

### 3. SSH commit signing

**Decided:** SSH signing via existing `~/.ssh/id_ed25519` key. Configuration:

```
gpg.format = ssh
user.signingkey = ~/.ssh/id_ed25519.pub
commit.gpgsign = true
tag.gpgsign = true
gpg.ssh.allowedsignersfile = ~/.config/git/allowed_signers
```

The `~/.config/git/allowed_signers` file lives on the operator's WSL host (per-machine state, not committed). Format is one line per allowed signer:

```
<email-principal> ssh-ed25519 <public-key-blob>
```

The actual key blob and SHA256 fingerprint are intentionally NOT recorded in this ADR — they're per-machine state, and embedding them here would (a) trip pre-commit's secret-detection hooks (high entropy, even though public), (b) drift from reality the moment the key is rotated, (c) duplicate information already verifiable via `git log --show-signature -1`.

To verify the current signing identity:

```bash
git log --show-signature -1                    # any signed commit
ssh-keygen -lf ~/.ssh/id_ed25519.pub           # current public-key fingerprint
cat ~/.config/git/allowed_signers              # configured trust anchor
```

GPG signing was rejected as overkill for a single-developer local edition; SSH signing achieves the same provenance goal with lower operational cost and is GitHub-natively verifiable if the project ever pushes to a remote.

### 4. Initial commit strategy

**Decided:** single "Initial state of SecForge platform (2026-05-01)" commit (`10c6a06`). Synthetic phase-by-phase backfill was rejected — PLAN.md and the ADRs already record the project's history with honest dates and explicit decision authorship; a synthetic git history would duplicate that with strictly-less-true metadata.

### 5. Remote

**Decided:** local-only for now. Revisit at Phase 9 (when real apps land) or cloud-migration time. Defensible because:

- Single-developer local edition; no collaborator coordination needed yet
- Backups are an existing operational concern (Docker Desktop volume snapshots, host-level OneDrive backup of `/mnt/c/Users/jaupo/Projects/`)
- The decision between Private GitHub vs. self-hosted Gitea is meaningful and shouldn't be made under tonight's "we just need git working" pressure

When a remote does land, the choice should consider: future Cosign keyless image signing via GitHub OIDC (favors GitHub), full sovereignty / no external dependency (favors Gitea), and whether the cluster will be the source of identity for git access (favors Gitea hosted in-cluster).

### 6. Pre-commit hooks

**Decided:** committed `.pre-commit-config.yaml` activates these hooks at every `git commit`:

- **gitleaks v8.18.4** — secret detection
- **trailing-whitespace** — hygiene
- **end-of-file-fixer** — hygiene
- **check-merge-conflict** — refuses merge-conflict markers
- **check-yaml** (with `--allow-multiple-documents`; excluded for `platform/manifests/*/vendor-chart/` because Helm templates contain Go-template syntax that breaks pure-YAML validation)
- **detect-private-key** — blocks accidentally-committed key blobs
- **check-added-large-files** with `--maxkb=500` (excluded for `apps/*/sbom/` because SBOMs are known-large supply-chain artifacts kept in tree by design)

The first run during initialization auto-fixed trailing whitespace on `apps/helloworld-bff/sbom/helloworld-bff.sbom.txt`, end-of-file fixes on `docs/03-runbooks/keycloak-operations.md` and `apps/helloworld-bff/dpop.go`, and surfaced one false positive (`detect-private-key` matched a literal PEM key block header phrase inside backticks in an earlier draft of this ADR; the prose was reworded to break the regex match while preserving meaning). Lesson learned: when documenting what a regex matches, never paste the literal trigger string into the doc itself — describe it.

Pre-flight gitleaks scan against the working tree returned **zero findings** — confirming the project's CLAUDE.md "no secrets in code, ever" rule has held across all 7 phases.

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
