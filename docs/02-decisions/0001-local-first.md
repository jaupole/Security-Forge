# ADR-0001: Build Local-First on Docker Desktop Kubernetes

**Status**: Accepted
**Date**: 2026-04-28
**Decision-makers**: Project owner

## Context

The SecForge platform supports three applications (Proposal Forge, Project Tracker, future PM app) that the owner is actively developing. The original plan targeted AWS as the deployment substrate. The owner has since decided that, while they're iterating on the application code and discovering the patterns, deploying to AWS is premature: it costs money, takes longer to redeploy, and adds complexity that gets in the way of experimentation.

The owner has a 32 GB development machine running Windows 11 with WSL2 and Docker Desktop. The three applications are not yet ready for production exposure. The owner has not yet committed to a specific cloud provider for eventual deployment.

## Decision

**Build the SecForge platform on Docker Desktop's built-in Kubernetes for the development phase. Defer the cloud-provider choice. Design every component so that migration is a substrate change, not a re-architecting.**

## Rationale

### Cost

Idle AWS deployment: ~$700/month baseline for the multi-environment cloud edition (3 EKS control planes, 5 RDS instances, NAT gateways). Active development with frequent rebuilds: $1k-2k/month. Local: $0/month.

### Iteration speed

Local cluster can be reset to clean state in minutes. AWS environment requires coordinated `terraform destroy` followed by re-apply, which takes 30-90 minutes. When you're learning the platform, you'll want to rebuild often.

### Cognitive load

Cloud adds: AWS account management, IAM policies, VPC design, security groups, billing alarms, NAT gateway costs, Route 53 DNS, multi-account coordination. None of these are SecForge-platform problems; they're cloud-platform problems. Deferring them lets the owner focus on the platform itself.

### Portability is preserved

The architectural choice that makes this safe: every component we use (Keycloak, SpiceDB, OpenBao, SPIRE, Istio, Wazuh, Cosign, Kyverno) is cloud-portable. The Helm charts run unchanged on Docker Desktop K8s, EKS, GKE, AKS, k3s, and self-managed Kubernetes. Only the substrate-dependent pieces change at migration time:

- Cloud KMS replaces file-based root keys
- Managed Postgres replaces in-cluster Postgres
- Managed object storage replaces MinIO
- Managed Kubernetes replaces Docker Desktop
- Real DNS replaces hosts-file entries
- Real CA replaces mkcert

These are bounded changes documented in migration playbooks.

### Defers the cloud-provider choice

The owner is not yet sure whether the eventual destination is AWS, a single VPS / homelab, or something else. Building local-first lets that decision happen later, with more information.

## Alternatives considered and rejected

### Build on AWS dev account (cheap tier) immediately

**Pros**: production-realistic from day one. No "two systems to maintain" risk.

**Cons**: $700+/month in baseline costs while iterating. Slow rebuild loop. Forces a cloud-provider decision the owner is not yet ready to make.

**Decision**: rejected. The cost-benefit doesn't favor cloud while the apps are still being designed.

### Use a hosted dev cluster (e.g., Civo, DigitalOcean Kubernetes)

**Pros**: real Kubernetes networking. Cheaper than AWS (~$30-50/month).

**Cons**: still introduces cloud-provider lock-in. Adds latency to every iteration. Not meaningfully more production-realistic than Docker Desktop K8s for the platform we're building.

**Decision**: rejected. The marginal benefit doesn't justify adding a third cloud account.

### Skip Kubernetes entirely; use docker-compose

**Pros**: simpler. Less RAM. Faster startup.

**Cons**: doesn't model the production deployment target. AuthorizationPolicy, NetworkPolicy, ServiceAccount-based attestation, Helm — none of these have docker-compose equivalents. The migration from "docker-compose works" to "Kubernetes works" is not free.

**Decision**: rejected. Local Kubernetes is more work upfront but pays back at migration time.

### Use kind or k3d instead of Docker Desktop K8s

**Pros**: kind/k3d are widely used in CI/CD; production K8s ops folks are familiar with them.

**Cons**: marginal benefits; the owner already has Docker Desktop, which provides K8s for free with no additional setup.

**Decision**: rejected. Docker Desktop K8s is convenient and sufficient. If the owner finds it limiting, they can switch to kind/k3d later — also a substrate change, also bounded.

## Consequences

### What this commits us to

- Maintaining a "Local Edition" set of Helm values and configurations alongside whatever cloud edition we eventually need.
- Documenting migration paths from local to cloud / VPS, so the move is mechanical when the time comes.
- Accepting that some production-grade properties (true KMS, multi-region, real DNS, immutable session recordings in object lock) are documented gaps for the local edition. Don't pretend they're solved when they aren't.
- Discipline to keep the architecture cloud-ready: not exploiting Docker Desktop quirks (e.g., `host.docker.internal`) in ways that bind us to that substrate.

### What this preserves

- All component choices are unchanged. Keycloak, SpiceDB, OpenBao, SPIRE, Istio, etc.
- All security patterns are unchanged: passkeys, BFF, SPIFFE workload identity, Postgres RLS, dynamic credentials.
- The eventual cloud migration is bounded to substrate-layer changes documented in migration playbooks.

### Known gaps in local edition (don't surprise yourself later)

These are deliberately accepted as not-production-ready:

1. **No real KMS.** Root keys are file-based, mounted as Kubernetes Secrets. On a laptop. Don't put real production data in this environment.
2. **No public TLS.** `mkcert` issues only locally-trusted certs. Anything external would fail.
3. **No public DNS.** Hosts file only.
4. **No HA.** Single replica per component. Single Kubernetes node.
5. **No real backups.** PVs survive on the Docker VM disk. Lose the disk, lose the data.
6. **Cosign signing uses a local key.** Production should use keyless via OIDC.
7. **No real workload identity federation.** SPIRE issues identities, but there's no AWS IAM / GCP service account / Azure AD on the other side to federate to.
8. **Wazuh ingestion is partial.** AWS CloudTrail and EKS audit logs (cloud-only sources) are obviously not present.

For each gap, the cloud-edition phase docs explain what fills it.

## Re-evaluation criteria

We revisit this decision if:

- Local performance becomes a development bottleneck that justifies a real cluster.
- The owner commits firmly to a cloud destination — at which point we activate the corresponding migration playbook and start a parallel cloud build.
- A customer requirement (data residency, audit, etc.) makes local development impractical even for the platform's own iteration.

## References

- [docs/99-archive/iam-oss-edition.md](../99-archive/iam-oss-edition.md) — full architecture and component rationale.
- [docs/99-archive/migration-to-aws.md](../06-reference/) — when you're ready to go to AWS.
- [docs/99-archive/migration-to-vps.md](../06-reference/) — when you're ready to go to a single server.
