# Glossary

If a term is used anywhere in this project's documentation and you don't know what it means, it should be here. If something's missing, add it.

---

**AAL (Authenticator Assurance Level).** A NIST scoring system for how strong an authentication is. AAL2 means "two factors, phishing-resistant preferred." AAL3 means "phishing-resistant required, hardware-bound." We target AAL2 by default and AAL3 for admin accounts.

**ADR (Architecture Decision Record).** A short Markdown document that records *why* we chose one approach over another. Stored in `docs/02-decisions/`. ADRs are append-only — when a decision changes, you add a new ADR that supersedes the old one rather than editing the old one.

**Ambient Mode (Istio).** A way of running Istio that doesn't require putting a "sidecar" container next to every application pod. Lighter, cheaper, and easier to operate at scale.

**API (Application Programming Interface).** The contract between two pieces of software. When the BFF talks to the Backend, they communicate via an API.

**ATO (Authority to Operate).** A formal approval that lets a system run in a federal environment. Granted after a security assessment.

**Authentication.** Proving who you are. ("This is Jason.")

**Authorization.** Determining what you're allowed to do. ("Jason is allowed to read this document but not delete it.")

**AWS (Amazon Web Services).** A cloud provider. Not used in the Local Edition; relevant if you eventually migrate.

**BCFIPS / BC-FIPS (Bouncy Castle FIPS).** A FIPS 140-validated cryptographic library used by Keycloak in compliance configurations. Not used in this OSS edition; relevant for the future CMMC upgrade.

**BFF (Backend-for-Frontend).** A small server-side component that sits between a browser-based application and the backend services. Browser sends a cookie to the BFF; BFF holds the OAuth tokens server-side; BFF talks to backend services on the user's behalf. Eliminates the entire class of "browser stole my token" attacks.

**Cert-manager.** A Kubernetes tool that automatically obtains and renews TLS certificates from Let's Encrypt.

**CMMC (Cybersecurity Maturity Model Certification).** A US Department of Defense compliance program. Required for contractors handling Controlled Unclassified Information. We're not pursuing it now but the architecture is designed to be upgradeable.

**Container.** A lightweight, isolated package that includes an application and everything it needs to run. The standard format is OCI (the more general name for "Docker images").

**CSP (Content Security Policy).** An HTTP response header that restricts what scripts a browser will execute. Critical defense against cross-site scripting (XSS) attacks.

**CSRF (Cross-Site Request Forgery).** An attack where one website tricks a browser into sending requests to another site where the user is logged in. Defended against with SameSite cookies and Origin/Referer header checks.

**CUI (Controlled Unclassified Information).** US government data that's sensitive but not classified. CMMC controls govern its handling.

**DPoP (Demonstrating Proof-of-Possession).** A way of binding an OAuth access token to a specific cryptographic key, so a stolen token alone is useless without the key. Each request carries a `DPoP` header with a fresh proof JWT covering the request's HTTP method (`htm`) and target URI (`htu`); the server verifies the proof signs against the key the token was bound to.

**Docker Desktop.** A desktop application that runs Docker (and optionally a small Kubernetes cluster) on Windows or Mac. Our Local Edition uses Docker Desktop's built-in Kubernetes.

**EKS (Elastic Kubernetes Service).** AWS's managed Kubernetes offering. Not used in Local Edition.

**FAPI (Financial-grade API).** A high-security profile of OAuth originally for banking. Its baseline is now used widely for any high-value API.

**FIDO2 / WebAuthn.** The modern standard for passkeys and security keys. A FIDO2 authenticator does cryptographic challenge-response that cannot be phished.

**FIPS 140-2 / 140-3.** US standards for cryptographic modules. A FIPS-validated module has gone through formal certification (the CMVP). Required for some government work, not used in this OSS edition.

**Helm.** A package manager for Kubernetes. A Helm "chart" is a templated set of Kubernetes manifests. Most components in this stack ship Helm charts.

**HSM (Hardware Security Module).** A specialized hardware device that stores cryptographic keys and performs operations on them without ever exposing the keys. Cloud KMS is HSM-backed.

**IAM (Identity and Access Management).** The general term for "who's who and what can they do." Also AWS IAM specifically refers to AWS's permission system.

**IRSA (IAM Roles for Service Accounts).** AWS's mechanism for letting Kubernetes workloads assume IAM roles without static credentials.

**JWKS (JSON Web Key Set).** A JSON document listing the public keys an issuer uses to sign JWTs. Verifiers fetch the JWKS from the issuer's well-known endpoint and look up the right key by `kid`. Keycloak publishes its JWKS at `/realms/<realm>/protocol/openid-connect/certs`.

**JWT (JSON Web Token).** A signed, self-contained token containing claims (e.g., "this user is Jason, role is admin, expires in 5 minutes"). Pronounced "jot."

**kid (Key ID).** A header field in a JWT that names which signing key was used. Verifiers use it to look up the right public key in the issuer's JWKS without trial-and-error. Keycloak indexes its JWKS by a DER-PKIX SHA-256 base64url shape; clients minting JWTs against Keycloak (e.g., `private_key_jwt`) must use the same shape.

**Keycloak.** The Identity Provider we're using. Open-source, written in Java, Apache 2.0 licensed.

**KMS (Key Management Service).** A service that stores encryption keys in hardware and lets applications use them. AWS KMS, Azure Key Vault, GCP Cloud KMS.

**Kubernetes (K8s).** A platform for running containerized applications across many machines. Runs here as single-node k3s on the Hetzner bare-metal host.

**kubectl.** The command-line tool for talking to Kubernetes.

**MFA (Multi-Factor Authentication).** Authentication using more than one factor (something you know, something you have, something you are). Passkeys count as MFA on their own because they combine "have" (the device) with "are" or "know" (biometric or PIN).

**mTLS (mutual TLS).** A TLS handshake where both sides present and verify a certificate, not just the server. The platform's Istio Ambient mesh uses mTLS between every workload — each pod has a SPIFFE-issued cert and only talks to pods that present a valid platform-issued cert.

**MinIO.** An open-source S3-compatible object storage server. Our Local Edition uses MinIO instead of AWS S3 for audit logs, backups, and session recordings.

**mkcert.** A small tool that creates a locally-trusted root CA on your machine, then issues certificates from it. Lets your browser trust `*.secforge.local` with no warnings, without paying for a real certificate. Local Edition only.

**MPL (Mozilla Public License).** An OSI-approved open-source license. OpenBao uses MPL 2.0.

**OAuth 2.1.** The current best-practice version of OAuth, in late draft. Mandates PKCE, eliminates the implicit and password grants, etc.

**OIDC (OpenID Connect).** A protocol layered on OAuth 2.0 for authentication. The "I want to log in with Google/Microsoft/etc." button uses OIDC.

**OpenBao.** Our secrets manager. Linux Foundation fork of Vault before HashiCorp's BSL relicense. MPL 2.0.

**Operator (Kubernetes).** A controller that knows how to operate a specific software product on Kubernetes. The Keycloak Operator manages Keycloak; SpiceDB has an operator; etc.

**PAR (Pushed Authorization Request).** An OAuth feature where the client sends authorization parameters to the server in a back-channel POST instead of in the URL. Eliminates URL-leak attacks.

**Passkey.** A FIDO2 credential, often synced across a user's devices via their phone/Apple/Google account. Replaces passwords.

**PEP / PDP (Policy Enforcement Point / Policy Decision Point).** PEP is the component that says "should I let this request through?"; PDP is the component that returns the answer (e.g., SpiceDB).

**PKCE (Proof Key for Code Exchange).** An OAuth feature that prevents an attacker who intercepts an authorization code from being able to use it. Pronounced "pixie."

**PKCS#11.** A standard API for talking to cryptographic devices (HSMs, smart cards, KMS).

**Postgres / PostgreSQL.** The relational database we're using. Open-source, widely deployed.

**RBAC (Role-Based Access Control).** A permission model where users are assigned roles, and roles have permissions. Simple but limited — we use it for the "platform tier" but use SpiceDB for finer-grained app and resource permissions.

**ReBAC (Relationship-Based Access Control).** A permission model where access is determined by relationships between subjects and resources (e.g., "user X is editor of folder Y"). What SpiceDB implements.

**Realm (Keycloak).** A namespace within Keycloak. Each tenant in our system gets its own realm so their identity data and signing keys are cryptographically isolated.

**Tenant.** A logically isolated customer of the platform. In Keycloak, one realm per tenant. In Postgres, every multi-tenant table carries a `tenant_id` and an RLS policy that prevents cross-tenant reads. In SpiceDB, the tenant is the top-level object in the three-tier ReBAC schema.

**Trust domain (SPIFFE).** The administrative scope of a SPIRE deployment, identified by its DNS-style root (in production: `secforge.platform`). Workloads in the same trust domain share one CA. Cross-domain trust requires explicit federation.

**RFC.** A formal technical specification (Request for Comments). RFC 9700 is the current OAuth 2.0 best-practices document.

**SAML.** An older single sign-on protocol, still required by many enterprise customers.

**SCIM (System for Cross-domain Identity Management).** A protocol for one identity system to provision users into another. Enterprise customers use it to push their employees into our system automatically.

**Sigstore / Cosign.** Tools for signing container images so we can prove they came from us.

**SOC 2.** A widely-used compliance framework, especially in B2B SaaS. We're targeting SOC 2 Type 2 readiness.

**SPIFFE / SPIRE.** SPIFFE is a standard for workload identity ("this container is running version X of service Y in environment Z"). SPIRE is the implementation we use. Each workload's identity is a **SPIFFE-ID** of the form `spiffe://<trust-domain>/...`; the platform's trust domain is `spiffe://secforge.platform`.

**SPIFFE-ID.** The URI-shaped name SPIRE assigns to a workload — e.g., `spiffe://secforge.platform/ns/app/sa/helloworld-backend`. Used as the `sub` of JWT-SVIDs and as the X.509-SVID's URI SAN. AuthorizationPolicies, OpenBao auth/jwt roles, and SpiceDB writers all reference SPIFFE-IDs to identify workloads.

**SpiceDB.** Our authorization engine. Open-source implementation of Google's Zanzibar paper.

**SSO (Single Sign-On).** Logging in once and being authenticated to multiple applications.

**Terraform.** An Infrastructure-as-Code tool. Not used here — the platform is deployed with pure Helm + kubectl manifests; relevant if you migrate to managed cloud.

**TLS (Transport Layer Security).** The encryption that secures HTTPS connections. We use TLS 1.3 only.

**Token (OAuth).** A credential issued by an IdP that a client uses to access a resource. Access tokens are short-lived; refresh tokens are longer-lived and can be exchanged for new access tokens.

**Valkey.** A BSD-3-Clause Linux Foundation fork of Redis. The planned session store for the Go BFF pattern; not currently deployed — the ecosystem apps use HttpOnly-cookie sessions.

**Vault.** HashiCorp's secrets manager. Now under BSL license; we use OpenBao instead.

**Wazuh.** Our SIEM (security information and event management). Aggregates logs, runs detection rules, manages compliance reporting.

**WSL2 (Windows Subsystem for Linux 2).** A Linux environment that runs alongside Windows. Lets you use Linux tooling on a Windows machine.

**XSS (Cross-Site Scripting).** An attack where attacker-controlled JavaScript runs in another user's browser. Defended against with CSP, input sanitization, output encoding.

**Zanzibar.** Google's internal authorization system, described in a 2019 paper. SpiceDB implements its model.
