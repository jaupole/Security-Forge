# Trivy accepted-baseline — container image CVEs

Trivy scans every running pod image weekly and posts CRITICAL findings to
Wazuh. Some CRITICAL CVEs persist in our images because the upstream
project hasn't published a patched build yet — when we're already at the
latest tag/digest, there's nothing actionable until upstream releases.

This document tracks those accepted-pending-upstream findings so the
weekly review focuses on NEW criticals rather than re-litigating known
ones.

Last reviewed: 2026-05-09 (Trivy run findings-20260509-1608.jsonl)
Linked tooling: [`platform/components/00d-upstream-image-check.sh`](../../platform/components/00d-upstream-image-check.sh) installs the weekly digest-check timer.

---

## How to use this document

1. **A new CRITICAL fires in Wazuh:** check this list first.
2. **CVE+image listed below as `upstream-fix-pending`:** no action; review on weekly cadence.
3. **CVE+image listed but `upstream now has a fix`:** remove from list, bump image.
4. **CVE+image NOT listed:** it's a new one — actionable; add to the relevant section after triage.

Review cadence: every Monday alongside the upstream-image-check timer
output. The check posts a syslog line `upstream-image-check: NEW DIGEST
AVAILABLE for <image>` whenever a tracked image has a newer digest in
the registry — that's our cue to bump and revisit this list.

---

## ingress-nginx/controller:v1.15.1

Helm chart `ingress-nginx-4.15.1`. Already at latest published chart and
matching controller image.

| CVE | Package | Fixed in | Status |
|---|---|---|---|
| CVE-2026-31789 | libcrypto3, libssl3, openssl (3 hits) | 3.5.6-r0 | Upstream-fix-pending: ingress-nginx hasn't released v1.15.2 with patched alpine OpenSSL package yet |

**Compensating control:** ingress-nginx is on the public path. Mitigations
relying on something other than a clean image:
- TLS termination uses Let's Encrypt certs validated through cert-manager
- All ingress traffic goes through Cloudflare DNS (option to enable proxy/WAF later)
- ingress-nginx pod is restricted: hostPort, cap_drop ALL, NetworkPolicy gated

**Upstream watch:** https://github.com/kubernetes/ingress-nginx/releases

---

## cloudnative-pg/postgresql:16.10-bookworm

CNPG-managed Postgres image used by `secforge-keycloak-db` and
`secforge-spicedb-db` clusters. Floating tag `16.10-bookworm` /
`16-bookworm` both currently point to digest `sha256:bf0b0ec76…`.

Fixed-by-upstream-rebuild (CNPG just needs to publish a new dated build with
the patched Debian package versions):

| CVE | Package | Fixed in | Hits |
|---|---|---|---|
| CVE-2025-15467 | openssl, libssl3 | 3.0.18-1~deb12u2 | 2 |
| CVE-2026-31789 | openssl, libssl3 | 3.0.19-1~deb12u2 | 2 |
| CVE-2025-6965 | libsqlite3-0 | 3.40.1-2+deb12u2 | 1 |

Fixed-by-postgres-binary-rebuild (CNPG needs to compile postgres with
newer Go stdlib; lower priority since these are stdlib bugs in the
Postgres binary itself, which doesn't expose net/http or html/template
in normal operation):

| CVE | Package | Fixed in | Hits |
|---|---|---|---|
| CVE-2023-24538 | Go stdlib | 1.19.8 / 1.20.3 | 1 |
| CVE-2023-24540 | Go stdlib | 1.19.9 / 1.20.4 | 1 |
| CVE-2024-24790 | Go stdlib | 1.21.11 / 1.22.4 | 1 |
| CVE-2025-68121 | Go stdlib | 1.24.13 / 1.25.7 | 1 |

Genuinely unfixed in Debian (waiting on Debian Security to backport):

| CVE | Package | Note |
|---|---|---|
| CVE-2023-45853 | zlib1g | "Unimportant" per Debian; no DSA expected |
| CVE-2025-7458 | libsqlite3-0 | Pending |
| CVE-2026-33845 | libgnutls30 | Pending |

**Compensating control:** Postgres listens only on its ClusterIP service
(no external exposure). Reachable only from Keycloak / SpiceDB pods
within the cluster. Authenticated via SCRAM-SHA-256, TLS 1.3 enforced
between client and server.

**Upstream watch:**
- https://github.com/cloudnative-pg/postgres-containers/releases
- https://security-tracker.debian.org/tracker/CVE-2023-45853

---

## cloudnative-pg/cloudnative-pg:1.29.0

CNPG operator image. Helm chart `cloudnative-pg-0.28.0`.

| CVE | Package | Fixed in | Status |
|---|---|---|---|
| CVE-2026-33816 | github.com/jackc/pgx/v5 | v5.9.0 | Operator 1.29.1 binary released with patched pgx, **but chart 0.28.1 not yet published** (Gap #28 in deployment plan). Awaiting helm chart release. |

**Compensating control:** The pgx memory-safety bug requires the
attacker to control SQL queries the operator sends. Operator only
queries CNPG-managed clusters using its own credentials — no external
input path.

**Upstream watch:** https://github.com/cloudnative-pg/charts/releases

---

## Acceptance criteria for adding to this list

To put a CVE on this list, ALL of these must be true:

1. The image we're using is already at the latest published tag/digest.
2. The CVE remediation requires upstream to publish a new image
   (i.e., we cannot fix it ourselves with a config change).
3. Either:
   - There's a documented fix path with an upstream issue/release tracker, OR
   - The CVE is "wait for distro" (Debian/Alpine package not yet patched).
4. A compensating control exists that bounds the actual impact below
   what the CVSS suggests.

If criteria 1–4 don't all hold: don't put it here. Either upgrade,
re-architect, or accept the risk explicitly with a different doc entry.

---

## Quarterly review

Every quarter (next: 2026-08-09), check this list against current upstream
state. CVEs that have been fixed should be removed and the corresponding
image bumped. CVEs still pending should have their compensating controls
re-validated.
