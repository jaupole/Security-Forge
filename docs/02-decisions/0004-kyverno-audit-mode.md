# ADR 0004 — Kyverno verify-signatures starts in Audit, pod-security in Enforce

**Status:** Accepted
**Date:** 2026-04-28
**Deciders:** SecForge maintainer (J. Aupole)

## Context

Phase 1.7 installs Kyverno with two ClusterPolicies:

1. **`verify-image-signatures`** — every container image must carry a Cosign signature from the SecForge key.
2. **`enforce-pod-security-restricted`** — every pod must satisfy the Kubernetes Pod Security Standards "restricted" profile.

Each policy can run in `Audit` (log violations to PolicyReports without blocking) or `Enforce` (deny on violation). The choice matters because every chart we install in Phase 1+ has to be admitted.

Constraints:
- CLAUDE.md: "Defense in depth — same locally and in cloud."
- CLAUDE.md: "Local is where you build the muscle memory."
- CLAUDE.md: "When you encounter a bright-line rule violation, flag it. Do not silently fix it."
- Practical reality: upstream Helm charts (cert-manager, ingress-nginx, Bitnami Valkey, MinIO, Wazuh, Prometheus, etc.) ship images that are usually NOT signed by anyone and certainly not by us.

## Decision

- **`verify-image-signatures`**: start in **Audit** mode locally. Flip to **Enforce** only after every platform image we depend on is either re-signed by our key or covered by a documented exception.
- **`enforce-pod-security-restricted`**: start in **Enforce** mode immediately. Workloads that legitimately need privileged are in `istio-system` and `spire`, both excluded; everything else must comply from day one.

## Rationale

### Why verify-signatures is Audit (for now)

Putting verify-signatures in Enforce on day one means the cluster refuses to install ingress-nginx, cert-manager, or any other upstream chart, because those images aren't signed by our key. Three options to get past that:

1. **Re-sign every upstream image we use** with the SecForge key, push to a private registry. Defensible, but 20+ images and a private registry are out of scope for Phase 1.
2. **Allow-list known-good upstream images** in the policy (skip signature check for them). Operationally simple, security-meh — we're trusting our allowlist hygiene.
3. **Run in Audit, observe, switch to Enforce when ready.** Doesn't gate Phase 1 progress; surfaces violations without blocking; gives us PolicyReports that document exactly what would be denied.

Option 3 wins for the local edition. The cost is one human-driven flip later, gated behind a checklist.

### Why pod-security is Enforce immediately

Pod Security Standards are a behavioral claim about how an image runs (non-root, drop capabilities, no privilege escalation, etc.) — not a supply-chain claim. Every well-maintained upstream chart already supports running under `restricted` (sometimes with values knobs we set in our values files). Failures here are real bugs we want to catch at admission, not in production.

The two namespaces that genuinely cannot be `restricted` (`istio-system` for ztunnel CNI, `spire` for hostPath access) are excluded explicitly. Everything else is covered.

## When verify-signatures flips to Enforce

Pre-conditions, in order:

1. Every image used by Phase 1–8 charts is either:
   - signed by our Cosign key, OR
   - covered by an explicit exclusion (image reference in the policy's exclude block) with a comment naming the upstream provenance we accept.
2. PolicyReports show **zero** open violations across all namespaces for 7 consecutive days.
3. The human (J. Aupole) explicitly approves the flip in conversation. Claude Code asks; doesn't decide.

Then: edit the policy's `validationFailureAction` from `Audit` to `Enforce`, apply, monitor for 24h.

## Consequences

**Positive:**
- Phase 1 install doesn't hard-fail on un-resigned upstream images.
- We start collecting baseline data (PolicyReports) about what would be denied if we did flip — driving the gap analysis honestly.
- pod-security catches real misconfigurations from day one (root containers, missing seccomp profiles, etc.).

**Negative:**
- The window between install and Enforce flip is a window in which a malicious image could in theory enter the cluster. Mitigations: (a) we only pull from known-good registries (`registry.k8s.io`, `quay.io`, `ghcr.io/cloudnative-pg`, `bitnami/`); (b) we log every admission via Wazuh in Phase 7; (c) the local cluster has zero exposure to anything beyond the host network, so blast radius is the laptop.
- Flipping Enforce later is a one-line change but requires verification — easy to forget. We track it in [PLAN.md](../../PLAN.md) under post-Phase-1 follow-ups.

## References

- Kyverno docs — Validation modes: https://kyverno.io/docs/policy-types/cluster-policy/validate/
- Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Phase 1.7 prompt: [phase-01-foundation.md](../05-claude-code-prompts/phase-01-foundation.md)
