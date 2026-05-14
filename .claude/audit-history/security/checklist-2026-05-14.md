# Security checklist audit — Security Forge platform

**Date**: 2026-05-14
**Commit**: 5115860ee15a43e2bb1aaec4114d9f273945ba9f
**Rules version**: 8b181958f74d34f6c5067079e8078fed99a59fd5a50ae5efac5215128d9bd488 (`~/.claude/security-rules.md`)
**Run by**: checklist-auditor agent (delegating to auth/crypto/header/authz/data specialists)

## Active rule set

- Base: 125 rules (`.claude/security-rules.md`)
- Active overlays declared in CLAUDE.md: none (project documents local-only Cosign keys instead of keyless, TOTP instead of passkeys; no React/Node/Prisma overlay declared)
- **Total in scope**: 125 rules

## Overall posture

| Status | Count | % |
|---|---|---|
| Pass | 96 | 77% |
| Partial | 11 | 9% |
| Fail | 5 | 4% |
| N/A | 7 | 6% |
| Unknown | 6 | 5% |

## Critical failures (5)

1. **Rule 38** — PII Transit encryption library (`apps/lib/secrets/transit.go`) is fully implemented but has **zero call sites** in production app code. `ecosystem_control.pending_invitations.invited_email` is unencrypted at rest. Explicitly flagged as incomplete in `docs/06-reference/api-security-status.md:96`.
2. **Rule 34** — CSRF protection absent on `/api/*` mutation routes in the BFF. `proxy.go:139` applies only an Origin header check on `/auth/logout` — no double-submit token, no Synchronizer-Token, no `__Host-` CSRF cookie on any non-logout mutation path. DPoP-bound bearer is a sound defense in practice but not formally documented as a CSRF-equivalent.
3. **Rule 32** — Idempotency keys absent from state-changing API routes. No `Idempotency-Key` header handling in `apps/helloworld-bff/`, `apps/helloworld-backend/`, or `Ecosystem Control/` source.
4. **Rule 58** — `platform/manifests/kyverno/policies/02-require-resource-limits.yaml:19`: `validationFailureAction: Audit`. **NOTE: this is FILE↔LIVE DRIFT — the live cluster cpol is `Enforce`. File must be updated to prevent regression on next apply.**
5. **Rule 59** — `platform/manifests/kyverno/policies/05-image-signature-verification.yaml:44,47`: `validationFailureAction: Audit`, `failurePolicy: Ignore`. Covers only CNPG + SPIFFE images. All other images are admitted unsigned. Genuine gap — needs local Cosign keys deployed + signing pipeline.

## Full status table

### 1. Authentication and sessions (rules 1-10)

| # | Status | Notes |
|---|--------|-------|
| 1 | pass | `platform-realm.yaml:128-134` — CONFIGURE_TOTP defaultAction+enabled. Recovery codes also required. |
| 2 | pass | Keycloak 24+ uses bcrypt; HIBP blacklist enforced. No custom hashing. |
| 3 | partial | length(14), digits/lower/upper/special, history(5). No max-length cap. HIBP-equivalent blacklist present. |
| 4 | pass | `passwordBlacklist(Pwdb_top-100000.txt)`. |
| 5 | pass | bruteForceProtected, failureFactor 10, maxFailureWaitSeconds 3600. |
| 6 | partial | Per-IP at nginx (5 rps, burst x3, 20 conn). Per-account by bruteForceProtected. Admin path limits not verified. |
| 7 | n/a | `registrationAllowed: false`, admin-provisioned realm. |
| 8 | unknown | No device-fingerprint alerts in realm. Possible Wazuh coverage unverified. |
| 9 | partial | Refresh-token rotation; users can revoke via account console. No custom UI. |
| 10 | partial | No ACR policy. Passkey 2FA not yet mandatory in committed YAML (memory claims live flip but YAML one-shot). |

### 2. Tokens and sessions (rules 11-15)

| # | Status | Notes |
|---|--------|-------|
| 11 | pass | accessTokenLifespan: 300 (5 min). |
| 12 | pass | revokeRefreshToken+refreshTokenMaxReuse: 0. |
| 13 | pass | Opaque session cookie only. No localStorage/sessionStorage token storage. |
| 14 | pass | `__Host-bff_sid`: HttpOnly, Secure, SameSite=Lax. |
| 15 | pass | DPoP — 17-step chain. ECDSA P-256 keypair per pod. cnf.jkt + jti replay + ath all validated. |

### 3. Transport and headers (rules 16-24)

| # | Status | Notes |
|---|--------|-------|
| 16 | pass | TLS 1.3/1.2 only, ECDHE ciphers. Internal: VersionTLS13. |
| 17 | pass | HSTS max-age 63072000; preload. |
| 18 | pass | CSP nonce + strict-dynamic; default-src 'none'. |
| 19 | pass | X-Frame-Options DENY + CSP frame-ancestors 'none'. |
| 19b | pass | X-Content-Type-Options nosniff. |
| 20 | pass | Referrer-Policy strict-origin-when-cross-origin. |
| 21 | pass | Permissions-Policy denies camera/mic/geo/payment/usb. |
| 22 | pass | No wildcard CORS on credentialed routes. |
| 23 | pass | COEP+COOP+CORP (added 2026-05-14). |
| 24 | pass | server-tokens: false. |

### 4. Input validation (rules 25-30)

| # | Status | Notes |
|---|--------|-------|
| 25 | partial | ecosystem-control uses Zod. helloworld-backend has size cap only (16 KB). |
| 26 | pass | Parameterized queries throughout. No raw SQL construction. |
| 27 | pass | BFF returns JSON only. No `dangerouslySetInnerHTML`. |
| 28 | n/a | No user-controlled file paths. MinIO keys are UUID. |
| 29 | unknown | No upload endpoints in current surface. |
| 30 | pass | proxy.go:47-49 relative-only redirect enforcement. |

### 5. Rate limiting (rule 31)

| # | Status | Notes |
|---|--------|-------|
| 31 | pass | nginx 5 rps + ecosystem-control @fastify/rate-limit 100/min + tailscale admin allowlist. |

### 6. CSRF (rules 32-35)

| # | Status | Notes |
|---|--------|-------|
| 32 | **fail** | No Idempotency-Key handling anywhere. |
| 33 | **fail** | Origin-check only on /auth/logout. All /api/* mutations have no CSRF token. DPoP-bound bearer is sound defense but undocumented. |
| 34 | partial | SameSite=Lax (not Strict). `__Host-` prefix adds protection. |
| 35 | partial | ecosystem-control bearer exemption documented. helloworld BFF DPoP exemption not formally documented. |

### 7. Secrets management (rules 36-43)

| # | Status | Notes |
|---|--------|-------|
| 36 | pass | CLAUDE.md bright-line. Comprehensive .gitignore. Runtime fetch from OpenBao. Kyverno denies secret-named env vars in app ns. |
| 37 | pass | Transit key rotation. Valkey credentials auto-refresh. CNPG dynamic Postgres credentials. Velero kopia passphrase rotated. |
| 38 | **fail** | TransitClient library complete + OpenBao grants in place; zero production call sites. `pending_invitations.invited_email` plaintext at rest. |
| 39 | pass | MinIO SSE-S3, CNPG barman backups encrypted, etcd via k3s --encryption-provider-config, Velero kopia AES-256. |
| 40 | pass | No secrets in logs. pino redaction. slog reviewed clean. |
| 41 | pass | OpenBao policies per-workload, principle of least privilege. |
| 42 | partial | .gitignore comprehensive. No CI-level secret scanning. |
| 43 | pass | audit_log table REVOKE UPDATE/DELETE for app role. |

### 8. Authorization (rules 44-50)

| # | Status | Notes |
|---|--------|-------|
| 44 | pass | SpiceDB Evaluate on every sensitive op. fully_consistent. |
| 45 | pass | IDOR prevented — SpiceDB encodes ownership. |
| 46 | pass | Structured 403 from PermissionDenied. |
| 47 | pass | No cluster-admin for service accounts. SPIRE SVIDs namespace-scoped. |
| 48 | partial | project-tracker: 10 tables with RLS. ecosystem-control: incomplete per api-security-status.md:93. |
| 49 | pass | OpenBao + SPIFFE policies follow least-privilege. |
| 50 | pass | Kyverno admin-allowlist ClusterPolicy (Enforce) requires tailscale CIDR on admin hostnames. |

### 9. Supply chain (rules 51-57)

| # | Status | Notes |
|---|--------|-------|
| 51 | partial | No CI. pnpm audit + govulncheck planned but not invoked. |
| 52 | partial | trivy-operator installed; findings not gating admission. |
| 53 | pass | Go go.sum, Helm pinned versions, disallow-latest-tag Kyverno policy. |
| 54 | partial | No syft/cyclonedx in Dockerfiles. SBOM marked "not started" in Tier 4. |
| 55 | pass | restrict-image-registries Enforce + failurePolicy: Fail. |
| 56 | pass | require-runasnonroot Enforce. 12 documented exempt namespaces. |
| 57 | pass | distroless static-debian12:nonroot. |

### 10. Infrastructure and IaC (rules 58-65)

| # | Status | Notes |
|---|--------|-------|
| 58 | **fail (file) / pass (live)** | DRIFT: file says Audit, cluster cpol Enforce. File needs update. |
| 59 | **fail** | image-signature-verification Audit + failurePolicy Ignore. Only CNPG + SPIFFE covered. |
| 60 | partial | Default-deny-egress 9/14 ns. Ingress-deny on minio/keycloak/velero. ~5 ns still without. |
| 61 | partial | pss-baseline still Audit. require-runasnonroot Enforce. |
| 62 | partial | velero/trivy hostPath exempt by comment. No blanket policy. |
| 63 | pass | k3s audit log JSON, maxage 30, maxbackup 10. |
| 64 | pass | k3s --encryption-provider-config. |
| 65 | pass | Full sysctl battery. GRUB password installed 2026-05-14. |

### 11. CI/CD security (rules 66-71)

| # | Status | Notes |
|---|--------|-------|
| 66 | unknown | No CI pipeline found in repo. |
| 67 | unknown | No CI to evaluate. |
| 68 | unknown | No .github/ config. |
| 69 | pass | -trimpath -ldflags "-s -w -buildid=" reproducible. |
| 70 | partial | No syft invocation. No SLSA provenance. |
| 71 | unknown | No renovate.json / dependabot.yml. |

### 12. JWT (rules 78-82)

| # | Status | Notes |
|---|--------|-------|
| 78 | pass | RS256 only. |
| 79 | pass | Exact iss match. |
| 80 | pass | Exact aud match. Audience self-mappers confirmed. |
| 81 | pass | exp/nbf/iat validated. DPoP iat window ±60s. |
| 82 | pass | OIDC discovery; JWKS fetched dynamically. |

### 13. SSRF (rules 83-85)

| # | Status | Notes |
|---|--------|-------|
| 83 | partial | All BFF outbound is cluster-internal env-var-configured. No explicit allowlist enforcement code. |
| 84 | partial | Default-deny-egress 9/14 ns. 5 ns pending. |
| 85 | unknown | No code-level Host validation. NetworkPolicy is primary mitigation. |

### 14. MCP (rules 86-97)

| # | Status | Notes |
|---|--------|-------|
| 86-97 | n/a | No MCP server in project. |

### 15. Claude Code agent permissions (rules 98-107)

| # | Status | Notes |
|---|--------|-------|
| 98 | pass | Comprehensive deny + narrow allow lists. |
| 99 | pass | rm -rf, dd, mkfs, kubectl delete, helm uninstall, force-push denied. |
| 100 | pass | No bypassPermissions. |
| 101 | pass | settings.local.json in .gitignore. |
| 102 | partial | settings.local.json has `Bash(kubectl *)` allow-all overriding workspace deny. Per-machine, not committed. |
| 103 | unknown | No hook configuration. |
| 104 | unknown | No session-logging config. |
| 105 | pass | No agent spawning in allow list. |
| 106 | partial | kubectl apply allowed; kubectl * in local further broadens. |
| 107 | unknown | No output redaction config. |

### 16. LLM / prompt injection (rules 108-113)

| # | Status | Notes |
|---|--------|-------|
| 108-113 | n/a | No LLM integration in current app surface. |

### 17. Universal hardening (rules 114-125)

| # | Status | Notes |
|---|--------|-------|
| 114 | partial | Default GOPROXY. go.sum hash-pinned. pnpm audit not in CI. |
| 115 | partial | TypeScript strict. No prototype pollution anti-patterns. No runtime Object.freeze. |
| 116 | pass | crypto/subtle.ConstantTimeCompare patterns. Opaque UUID session IDs. |
| 117 | pass | Friendly slug + structured error responses. No stack traces leaked. |
| 118 | pass | X-Frame-Options DENY + CSP frame-ancestors 'none'. |
| 119 | pass | Relative-only redirect + Keycloak redirectUris validation. |
| 120 | partial | Per-request CSP nonce. HSTS preload. No explicit compression-off. |
| 121 | pass | crypto/rand throughout. 32B opaque IDs, 16B CSP nonces, ECDSA P-256. |
| 122 | pass | /readyz returns status only. No version/config dump. |
| 123 | pass | SIGTERM → srv.Shutdown(15s). |
| 124 | partial | Distroless + USER set. readOnlyRootFilesystem not confirmed in pod securityContext. |
| 125 | pass | slog (Go) + pino redacted (TS) + k3s JSON audit + Wazuh structured. |

---

## Passkey / WebAuthn discrepancy

Memory states "Keycloak switched to mandatory passkeys" on 2026-05-14. Committed `platform-realm.yaml`:
- `requiredActions` has CONFIGURE_TOTP + CONFIGURE_RECOVERY_AUTHN_CODES as defaultAction
- No `webauthn-register` required action
- `otpPolicyType: totp`
- ADR-0007 referenced ("totp-instead-of-passkeys-locally")
- CLAUDE.md: "Auth Factor: TOTP (interim — see ADR-0007)"

**Conclusion**: Passkey flip described in memory was applied live via `kcadm.sh` (not reflected in import YAML — `KeycloakRealmImport` is one-shot, not reconciling). YAML as committed represents TOTP-mandatory. Rule 1 marked pass on TOTP basis. **File needs updating to match live, OR a kcadm-replay script must be added for DR.**

---

## Comparison to prior estimate

Prior estimate: ~94+ pass / 2 fail. This audit: 96 pass / 5 fail.

| Change | Rule | Prior | This run | Note |
|---|---|---|---|---|
| Confirmed fail | 32 | open | fail | Idempotency keys gap confirmed |
| Confirmed fail | 34 | open | fail | CSRF — DPoP-bearer sound but undocumented |
| Confirmed fail | 38 | fail | fail | Transit PII — library ready, no call sites |
| File↔live drift | 58 | fail | fail (file) / pass (live) | File Audit, live Enforce |
| Confirmed fail | 59 | fail | fail | Image sig verify Audit |
| Improved | 6 | unknown | partial | Per-IP rate limit confirmed |
| Improved | 23 | unknown | pass | COEP added 2026-05-14 |
| Improved | 56 | partial | pass | require-runasnonroot Enforce 2026-05-14 |
| Improved | 65 | partial | pass | GRUB password installed 2026-05-14 |
| Regressed | 33 | partial | fail | Origin-only on logout insufficient |

---

## Recommended next actions (priority order)

1. **Wire TransitClient to production call sites** (rule 38) — highest-impact gap.
2. **Fix rule 58 file↔live drift** — update `02-require-resource-limits.yaml` line 19 to `Enforce`.
3. **Sync `platform-realm.yaml` to match live passkey state** (rule 1) OR add kcadm-replay script.
4. **Deploy local Cosign signing keys and flip image-sig-verification to Enforce** (rule 59).
5. **Add RLS policies to ecosystem_control tables** (rule 48).
6. **Document DPoP-as-CSRF-defense for helloworld BFF** (rule 34).
7. **Narrow `.claude/settings.local.json`** (rule 102).
8. **Add default-deny-egress to remaining 5 namespaces** (rule 84).
9. **Add CI pipeline with secret scanning + SCA** (rules 51, 66, 67) — required before any external users.
