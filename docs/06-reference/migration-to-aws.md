# Migration Playbook: Local → AWS

> **Snapshot date: 2026-05-04 (post-Phase 9).** This playbook assumes Phases 1–9 of the local build are complete (SPIRE / Keycloak / SpiceDB / OpenBao / Istio Ambient / BFF + api-auth library + outbound-secrets / observability stack / Teleport CE / Hello World end-to-end checkpoint). Phase 10 (per-app integration) reuses the same pattern in the cloud destination — repeat per app rather than restarting from Phase 1. If your local cluster is in an earlier state, complete the missing phases locally first; this playbook is not a shortcut. Cloud-edition specifics (KMS instead of Transit-on-OpenBao, S3 with Object Lock instead of MinIO, IRSA instead of SPIFFE-bound OpenBao roles, Teleport Enterprise with OIDC restored, etc.) are listed in the substrate-changes table below.

This is the playbook for moving the SecForge platform from your local Docker Desktop Kubernetes cluster to AWS. This is the **most expensive but most managed** destination — you trade ~$700-1500/month baseline for cloud-provider attestation, multi-region capability, and reduced operational overhead.

---

## When to choose this path

Pick AWS if any of these apply:
- You need SOC 2 / ISO 27001 / HIPAA / FedRAMP attestation paths
- You'll have customers who ask "where is my data hosted"
- You need multi-region failover (DR)
- You're building toward an enterprise sales motion
- You expect to scale to thousands of QPS where managed services pay back
- You want to focus engineering effort on product, not infrastructure

Don't pick this if:
- You're cost-constrained and have <100 active users
- Your operational scale is low and a VPS would suffice (see `migration-to-vps.md`)
- You're philosophically opposed to cloud lock-in (use the VPS path or build on a Kubernetes-portable cloud-agnostic stack)

---

## Major substrate changes

| Local | AWS |
|---|---|
| Docker Desktop K8s (1 node) | EKS (3 clusters: dev, staging, prod; 3-AZ each) |
| Postgres pods | RDS Postgres (Multi-AZ in prod) |
| Valkey pod | ElastiCache Valkey |
| MinIO | S3 (with Object Lock for audit) |
| File-based KMS | AWS KMS (FIPS-validated, optionally CloudHSM) |
| mkcert local CA | cert-manager + Let's Encrypt (or AWS Certificate Manager for ALB) |
| hosts file | Route 53 |
| Pure Helm | Terraform + Helm |
| OpenBao file storage | OpenBao Raft on EBS, snapshots to S3 |
| Single account | Multi-account Organization (security/dev/staging/prod) |
| Direct kubectl | Teleport-mediated access only |
| No federation | SPIRE federated to AWS IAM (workloads can assume IAM roles) |

---

## Cost estimate

The cloud-edition full deployment (3 environments) runs about:
- EKS control planes: 3 × $73 = $219
- EC2 worker nodes (12 nodes total, mixed sizes): ~$300
- RDS instances (5 across environments): ~$150
- ElastiCache: ~$80
- NAT Gateways (3 envs × 3 AZs = 9): ~$300
- ALBs: ~$50
- Route 53: ~$5
- KMS: ~$10
- CloudWatch + GuardDuty + Config: ~$50
- S3 + EBS storage: ~$30
- Data transfer: variable, ~$50-200

**Baseline ~$1244/month** for full multi-environment deployment with light traffic. Production-only single-environment is ~$700/month.

You can cost-optimize significantly:
- Use a single environment and namespaces for dev/staging/prod separation (saves ~$500/month, less defense-in-depth)
- Use Spot Instances for non-critical workloads
- Use Aurora Serverless v2 instead of RDS Postgres (better at variable load)
- Reserved Instances for sustained baseline (1-year RI saves ~30%)

---

## Phased migration

### Phase A: AWS Account Setup (3-5 days)

This is the work that doesn't exist in local edition.

1. **AWS Organization** with separate accounts:
   - `secforge-management` (billing, IAM Identity Center)
   - `secforge-security` (centralized logging, GuardDuty admin)
   - `secforge-dev`, `secforge-staging`, `secforge-prod`
2. **AWS IAM Identity Center** federated to your IdP (or use it standalone)
3. **AWS SCP** (Service Control Policies) restricting what each account can do (deny actions outside allowed regions, deny disabling CloudTrail, etc.)
4. **CloudTrail** organization-wide trail to centralized S3 bucket with Object Lock
5. **GuardDuty** organization-wide
6. **AWS Config** organization-wide with conformance packs (CIS, NIST 800-53)
7. **Cost & billing alarms** per account
8. **Domain in Route 53**

This phase has its own dedicated documentation in the AWS Edition's Phase 0 docs, if you have them. If you don't have those, refer to AWS's Well-Architected security pillar.

### Phase B: Foundation (5-7 days)

Apply the AWS Edition's Phase 1 prompts. This includes:
- VPC with public/private/database subnets across 3 AZs (or 2 in dev for cost)
- EKS cluster (Cilium CNI replacing kube-proxy, kube-system addons)
- Karpenter for node autoscaling
- AWS Load Balancer Controller
- External DNS (auto-creates Route 53 records)
- cert-manager + Let's Encrypt or AWS PCA
- AWS KMS keys for: EKS envelope encryption, RDS, S3, EBS, OpenBao seal
- IRSA (IAM Roles for Service Accounts) configured

### Phase C: Re-deploy platform (5-7 days)

Apply each platform component using the AWS-edition prompts. Notable adjustments from local:

- **SPIRE**: Add `aws_iid` node attestor in addition to `k8s_psat`. Configure federation to AWS STS so workloads can present JWT-SVIDs to AWS and get back IAM credentials.
- **Keycloak**: Add the AWS KMS PKCS#11 provider for realm signing keys (FIPS-grade key custody). **Hardware FIDO2 keys required at this point** — per [ADR-0002](../02-decisions/0002-local-passkey-via-windows-hello.md), local edition uses Windows Hello as the admin passkey, but any AWS deployment is a reversal trigger. Before cutting users over: order two Token2 PIN+ keys (or YubiKey 5 / SoloKey v2), register both to admin accounts in Keycloak, then tighten the WebAuthn policy (`Attestation Conveyance: direct`, `Authenticator Attachment: cross-platform` for the admin role). Verify break-glass account credentials are still recoverable and stored offline. For multi-environment promotion, hardware keys are required for staging and prod admin access; dev environment may continue to allow platform authenticators.
- **OpenBao**: Replace local Transit-seal pattern with `aws-kms` seal type pointing at KMS. Backups go to S3.
- **MinIO** → S3: Replace MinIO with direct S3 usage. Bucket policies, Object Lock for audit logs.
- **Wazuh**: Receives CloudTrail and GuardDuty events in addition to local sources.
- **Teleport**: Same setup but now actually replaces SSH (production-realistic).

### Phase D: Apps re-deploy (1-2 days per app)

Apps move with minimal changes:
- Container images: push to ECR instead of (or in addition to) being loaded into local Docker
- Helm value overrides for: hostnames, S3 bucket names instead of MinIO, ElastiCache endpoint instead of in-cluster Valkey, IAM role ARNs for IRSA
- Database connection strings: RDS endpoints

The application code itself doesn't change. The Helm charts have additional values for cloud-specific features but the same underlying templates.

### Phase E: Multi-environment promotion (3-5 days)

- Set up GitHub Actions CI/CD with OIDC federation to AWS (no static credentials)
- Promotion: PR merged → builds image → pushes to ECR → deploys to dev → manual approval → deploys to staging → manual approval → deploys to prod
- Cosign keyless signing using GitHub OIDC (replaces local key)

### Phase F: Backups and DR (2-3 days)

- RDS automated backups + cross-region snapshot copy
- EBS snapshots via Velero
- S3 cross-region replication for audit logs
- OpenBao snapshot Lambda triggered nightly to backup S3 bucket
- Documented and *tested* DR runbook (target RTO 2 hours, RPO 5 minutes)

### Phase G: Compliance preparation (ongoing)

- AWS Config conformance packs for SOC 2, NIST CSF, CIS, etc.
- Audit Manager assessments
- Documented security policies (AUP, incident response, change management)
- Vendor questionnaire response template
- Pen test (annual after launch)

---

## What stays the same

Same as the VPS migration:
- Application code (BFF, backends, frontends)
- SpiceDB schema
- OpenBao policies
- Wazuh detection rules
- Grafana dashboards
- The architecture document
- Most of CLAUDE.md (with cloud-specific updates)

Same ~80% portability claim.

---

## What's genuinely new

- IAM (the AWS kind, not the platform kind): roles, policies, IRSA, federation patterns
- Multi-account organization design and SCPs
- Network design: VPC, subnets, route tables, security groups, NAT gateways
- KMS key design: which key for what, who can use which, rotation policy
- Compliance overlays: Config rules, Audit Manager, conformance packs
- Cost management: budgets, alarms, RI/SP planning

This is genuinely 4-6 weeks of work for someone seeing it for the first time. If you have AWS experience already, 2-3 weeks.

---

## Migration risks and how to manage them

### Risk: Substrate change breaks things you didn't realize depended on local
**Mitigation**: Bring up the AWS environment fully in parallel with local. Don't decommission local until everything works in dev/staging.

### Risk: AWS bill explodes
**Mitigation**: Set hard billing budgets per account. Use Cost Explorer weekly. NAT Gateway costs are the surprise — for dev, consider VPC endpoints or NAT Instances instead.

### Risk: Misconfigured IAM permissions leak data
**Mitigation**: Use AWS IAM Access Analyzer in every account. Run Prowler regularly. Pen-test before exposing publicly.

### Risk: KMS key gets accidentally scheduled for deletion (data loss!)
**Mitigation**: SCP at organization level denying KMS key deletion. Rotation only via approved process.

### Risk: Cosign keyless via OIDC has subtle config issues
**Mitigation**: Test every workflow before relying on it. Have a fallback to break-glass key signing if OIDC chain breaks.

---

## Hybrid: local for dev, AWS for staging+prod

A reasonable middle path: keep your local environment as the primary developer iteration space, deploy only staging and prod to AWS. This:
- Saves ~$300/month (no AWS dev account costs)
- Lets you keep iterating fast
- Forces "the staging environment is production-like" discipline (you can't just SSH and tweak)
- Means dev → staging promotion is a substrate change, but it's a managed one

The AWS Edition phase docs were written assuming three AWS environments; you'd skip the dev account and adapt the docs to "local is dev."

---

## Resources

- [AWS Well-Architected Framework](https://aws.amazon.com/architecture/well-architected/)
- [EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/)
- [AWS IAM Identity Center](https://aws.amazon.com/iam/identity-center/)
- [SPIRE AWS IID node attestor](https://github.com/spiffe/spire/blob/main/doc/plugin_server_nodeattestor_aws_iid.md)
- [Cosign keyless signing with GitHub OIDC](https://docs.sigstore.dev/cosign/signing/overview/)
- The AWS Edition's Phase 0-10 prompt documents (if you preserved them) become the operational checklist for this migration
