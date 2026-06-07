# DPoP `htu` canonicalization — single-source rule

> **Audience:** every BFF and every backend that MINTS or VALIDATES a DPoP proof.
>
> Companion: [04-bff-pattern.md § DPoP key lifecycle](../01-architecture/04-bff-pattern.md#dpop-key-lifecycle), [ADR-0011](../02-decisions/0011-bff-single-replica-local.md), [ADR-0014](../02-decisions/0014-api-auth-library-design.md).

This document is the platform-wide source of truth for how `htu` is computed and validated. The rule is duplicated NOWHERE: every consumer (BFF, backend APIs starting in Phase 9, AuthZEN-façade in any future DPoP-aware extension, the [`apps/lib/api-auth`](../../apps/lib/api-auth) middleware Phase 6b-1 builds) reads from here. Closes F-ADR-3.

---

## Why this rule needs to be central

`htu` (HTTP target URI) is the request URL the DPoP proof binds to. If the minter computes `htu` one way and the validator computes it differently, every DPoP-bound call fails — silently, with `401` and no obvious cause. CLAUDE.md "local gotcha #3" warns about exactly this: a stray port (`:8443` vs implicit `:443`), a trailing slash, a query string, the difference between `X-Forwarded-Host` and `r.Host`. Each of these is a place where mint-vs-validate diverges by accident.

Every DPoP implementation in the platform follows this rule verbatim. Drift is a defect.

---

## The canonicalization rule

```
canonical_htu(url) =
    lowercase(scheme) + "://"
  + lowercase(host)
  + (port if non-default-for-scheme else "")
  + path                              // verbatim, including trailing slash if any
  // NO query string, NO fragment, NO username/password
```

Where:

- **`scheme`**: `https` or `http`, lowercased. Mixed case (`HTTPS://`) is reduced to lowercase.
- **`host`**: the registered DNS name or IP literal, lowercased. IPv6 literals keep their bracket form (`[::1]`) but the literal itself stays lowercase. Internationalized hostnames are in their A-label (Punycode) form, not the U-label — DPoP runs at the wire layer, never at display layer.
- **`port`**: 443 for https, 80 for http are the defaults and MUST be omitted. Any other port is included verbatim. **Ambiguous case**: an explicit `:443` on an https URL is canonicalized to no port — implicit-vs-explicit defaults are equivalent.
- **`path`**: kept as-is from the request line. The platform does NOT normalize trailing slashes, NOT normalize percent-encoding, NOT collapse `..` segments. Whatever the wire said, that's what `htu` carries. If the path on the request line and the validator's expected path differ in a way that normalization would mask, that mismatch is an explicit failure (incident), not a silent pass (gotcha).
- **NO query string, NO fragment, NO userinfo (`user:password@`)**: stripped. Per RFC 9449 §4.3.

### Worked examples

| Request URL | Canonical `htu` |
|---|---|
| `https://app.secforge.dev/api/orders` | `https://app.secforge.dev/api/orders` |
| `HTTPS://APP.SECFORGE.LOCAL:443/api/orders` | `https://app.secforge.dev/api/orders` |
| `https://app.secforge.dev:8443/api/orders` | `https://app.secforge.dev:8443/api/orders` |
| `https://app.secforge.dev/api/orders?id=42` | `https://app.secforge.dev/api/orders` |
| `https://app.secforge.dev/api/orders/` | `https://app.secforge.dev/api/orders/` (trailing slash kept) |
| `https://user:pass@app.secforge.dev/api` | `https://app.secforge.dev/api` (userinfo stripped) |

### Anti-pattern (what the rule deliberately does NOT do)

Some DPoP implementations normalize path (collapsing `//` to `/`, decoding `%2F`, removing trailing slash). The platform deliberately does not. The reasoning: the BFF and the backend MUST agree on the exact path string before normalization, because any normalization the validator does that the minter doesn't (or vice versa) is a mint-vs-validate divergence. Treating the path as opaque means the only way to trip a DPoP-validate mismatch is for the request itself to differ at the wire, which is a real bug to surface — not silently mask.

---

## Source of `htu` per minting site

### BFF — inbound request (BFF validates the browser's DPoP-bound session)

The BFF computes the canonical `htu` from request headers, NOT from its own URL config or `r.Host`. Specifically:

- `scheme` from `X-Forwarded-Proto` (set by ingress-nginx, always `https` in practice)
- `host` from `X-Forwarded-Host` (set by ingress-nginx, `app.secforge.dev`)
- `path` from `r.URL.Path` (request line)

`X-Forwarded-*` is the wire truth (what the browser saw); `r.Host` would be the internal Service name and would silently break the DPoP chain.

**Fail-closed on missing forwarded headers.** If `X-Forwarded-Proto` or `X-Forwarded-Host` is absent on an inbound request that requires DPoP validation, the BFF returns `400` with `{"error":"missing_forwarded_headers"}`. The BFF MUST NOT fall back to `r.Host` or `r.TLS != nil`. Those fallbacks would silently re-enable connections that bypassed ingress-nginx (a misconfigured port-forward, a debug Service, a direct-pod-IP probe), producing DPoP proofs whose `htu` matches an internal-only URL. The backend's own canonical_htu would mismatch and the call would 401 with no obvious cause — exactly the gotcha. Fail-closed at the inbound boundary makes it loud.

### BFF — outbound request (BFF mints DPoP proof for backend call)

`htu` is the EXACT URL the BFF dialed: the upstream-service URL from the BFF's reverse-proxy route table. No header involvement (no proxy in front of the BFF→backend hop in the local edition; Phase 6b-1's outbound mints use the same).

### Backend / `apps/lib/api-auth` middleware — inbound validation

The backend computes the canonical `htu` from the **same source** the BFF used: forwarded headers if a proxy is in the path, `r.URL` directly if not. Whichever source matches the original mint site's source. For backends behind ingress-nginx, this is the `X-Forwarded-*` case. For backends called only inside the mesh (no ingress hop), this is the direct case.

`apps/lib/api-auth/Middleware.ValidateInbound` (Phase 6b-1 [ADR-0014](../02-decisions/0014-api-auth-library-design.md)) implements this rule. Backends DO NOT implement it themselves; they consume the middleware.

---

## DPoP proof attributes that are NOT `htu`

- `htm`: the HTTP method (`GET` / `POST` / etc.). Verbatim from the request, uppercase. No canonicalization needed beyond case.
- `iat`: timestamp at proof generation. Validators allow ±60 s of clock skew; outside that window, reject.
- `jti`: a fresh UUID per proof. Replay-cache for ≥ 60 s + skew tolerance, per [ADR-0014 § Middleware.ValidateInbound](../02-decisions/0014-api-auth-library-design.md#library-api-surface) step 15.
- `cnf.jkt` on the access token (issued by the IdP) MUST equal the SHA-256 thumbprint of the JWK in the DPoP proof's protected header. This is the proof-of-possession step.

---

## Cross-references for consumers

When you build a new component that mints or validates DPoP proofs:

| You're building | You consume | Where it implements this rule |
|---|---|---|
| A backend API (Phase 9+) | `apps/lib/api-auth/Middleware` | `ValidateInbound` does the canonicalization for you |
| A new BFF for a new app | The DPoP canonicalization in `apps/lib/api-auth` (the `helloworld-bff` demo that used it was removed) | Already correct; copy the pattern |
| A future direct-DPoP test client | This document | Implement `canonical_htu` per the rule above; do not normalize the path |
| A custom auth-proxy | This document | Same |

---

## Re-evaluation triggers

- A real-world bug surfaces a case this rule doesn't cover (e.g., IPv6 zone-id form, or a proxy that re-encodes `%2F` to `/`) → supersede with a new rule explicitly covering it. Do NOT silently extend this doc — every consumer's mint vs validate has to be re-audited against the change.
- The platform adopts a non-RFC-9449 proof-of-possession mechanism (e.g., mTLS-bound tokens via RFC 8705) → a new doc; this one stays for DPoP consumers.
- A future Keycloak version changes its `htu` validation semantics (e.g., requires path normalization) → reconcile via a Keycloak-specific note here AND a Phase 7d follow-up to align minter behavior. **Do not silently follow Keycloak's drift** — the rule's job is to be the same on every consumer.
