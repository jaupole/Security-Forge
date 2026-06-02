# syntax=docker/dockerfile:1.24@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89
# SecForge custom Keycloak image — optimized + HIBP password blacklist baked in.
#
# Why custom: the live deployment uses `KC_FEATURES=recovery-codes,dpop,organization` baked
# at build time, AND a 100k-entry HIBP password blacklist mounted at
# /opt/keycloak/data/password-blacklists/Pwdb_top-100000.txt. Without baking
# both into the image, we have:
#   - DR drift: a fresh cluster comes up missing one or both
#   - admission inconsistency: ConfigMap-mounted blacklist needs operator-
#     managed StatefulSet patching, which the Keycloak Operator may revert
#   - per-start cost: without `kc.sh build` pre-augmentation, Quarkus
#     re-augments on every pod start (slow + needs writable rootfs)
#
# Output image: ghcr.io/jaupole/keycloak@sha256:<digest> (signed via Cosign
# keyless from GitHub Actions OIDC — see .github/workflows/keycloak-image-build.yml).

# Keycloak version + base-image digest. KEYCLOAK_VERSION is a real ARG (not a
# Renovate-only template) so Renovate's customManager can surface AND apply
# Keycloak version bumps; KEYCLOAK_BASE_DIGEST pins the exact build of that
# version. Bump them together. FROM uses tag@digest — the digest still wins
# for what is pulled; the tag is for human + Renovate readability.
ARG KEYCLOAK_VERSION=26.6.2
ARG KEYCLOAK_BASE_DIGEST=sha256:f9ba7b2af90db8dc749a57ca9aedca51e840cb9224441ab546a968da941da900
# checkov:skip=CKV_DOCKER_7: the base image is pinned by digest via KEYCLOAK_BASE_DIGEST (stronger than any tag); the :${KEYCLOAK_VERSION} tag is for readability/Renovate tracking only. checkov cannot resolve the ARG-based digest.
FROM quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}@${KEYCLOAK_BASE_DIGEST}

# HIBP-derived top-100k password blacklist. Source: danielmiessler/SecLists
# (de facto reference set used by the security community). Pinned to a
# specific commit SHA so the URL is immutable; bump COMMIT + SHA256 together
# when refreshing (annually or on demand).
ARG PWDB_COMMIT=57af8077f81921fe34fefed01177b05bae2fa2f8
ARG PWDB_URL=https://raw.githubusercontent.com/danielmiessler/SecLists/${PWDB_COMMIT}/Passwords/Common-Credentials/Pwdb_top-100000.txt
ARG PWDB_SHA256=07f876a616f08fb2cc5c3e0ce04e4a6d1123380580472b0997baebc4e8226977

# BuildKit native: fetch + checksum-verify + chown + chmod in one declarative
# step. No curl-in-image, no shell escape hatches, fails the build loudly
# if the upstream content changes.
# checkov:skip=CKV_DOCKER_4: ADD is required here — it fetches a URL with checksum verification; COPY cannot fetch URLs.
ADD --chmod=0444 --chown=1000:0 --checksum=sha256:${PWDB_SHA256} \
    ${PWDB_URL} \
    /opt/keycloak/data/password-blacklists/Pwdb_top-100000.txt

# Pre-build (`kc.sh build`) with EVERY build-time option the live Keycloak CR
# relies on, so the runtime pod can start with `--optimized`. With --optimized
# Keycloak skips augmentation and REJECTS any build-time option supplied at
# runtime that differs from what is baked here — a mismatch crash-loops the
# pod. KC_HEALTH/METRICS/TRACING_ENABLED + KC_CACHE must stay in lockstep with
# the CR's additionalOptions (health-enabled, metrics-enabled, tracing-enabled).
#
# Only build-time options belong here; adding one means updating the CR too.
# Runtime options (log-level, tracing-endpoint, spi-*, db-url-properties, …)
# stay in the CR alone.
ENV KC_FEATURES=recovery-codes,dpop,organization
ENV KC_DB=postgres
ENV KC_CACHE=ispn
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_TRACING_ENABLED=true
RUN /opt/keycloak/bin/kc.sh build

# ENTRYPOINT + CMD are inherited from the base image; the Keycloak Operator
# passes start args via the Keycloak CR. USER is declared explicitly — the
# base already runs as 1000; this makes the non-root runtime intent
# explicit (checkov CKV_DOCKER_3).
USER 1000
