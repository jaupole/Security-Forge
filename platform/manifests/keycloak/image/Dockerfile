# syntax=docker/dockerfile:1.7
# SecForge custom Keycloak image — optimized + HIBP password blacklist baked in.
#
# Why custom: the live deployment uses `KC_FEATURES=recovery-codes,dpop` baked
# at build time, AND a 100k-entry HIBP password blacklist mounted at
# /opt/keycloak/data/password-blacklists/Pwdb_top-100000.txt. Without baking
# both into the image, we have:
#   - DR drift: a fresh cluster comes up missing one or both
#   - admission inconsistency: ConfigMap-mounted blacklist needs operator-
#     managed StatefulSet patching, which the Keycloak Operator may revert
#   - per-start cost: without `kc.sh build` pre-augmentation, Quarkus
#     re-augments on every pod start (slow + needs writable rootfs)
#
# Output image: ghcr.io/secforge/keycloak@sha256:<digest> (signed via Cosign
# keyless from GitHub Actions OIDC — see .github/workflows/keycloak-image-build.yml).

ARG KEYCLOAK_BASE_DIGEST=sha256:6a7217a100bd3e5de4063a27a538ef999a3c5a88c4b4ec0ffc0a642aee7b2597
FROM quay.io/keycloak/keycloak@${KEYCLOAK_BASE_DIGEST}

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
ADD --chmod=0444 --chown=1000:0 --checksum=sha256:${PWDB_SHA256} \
    ${PWDB_URL} \
    /opt/keycloak/data/password-blacklists/Pwdb_top-100000.txt

# Pre-build with the features used by the live deployment so the runtime
# pod starts with `--optimized` (no per-start Quarkus re-augmentation, no
# writable rootfs requirement).
#
# Adding a feature here: update both this ENV and the live Keycloak CR's
# kc-features arg if specified; rebuild + rotate image digest.
ENV KC_FEATURES=recovery-codes,dpop
ENV KC_DB=postgres
RUN /opt/keycloak/bin/kc.sh build

# (USER, ENTRYPOINT, CMD all inherited from the base image — no override
# needed. Keycloak Operator passes the start args via the Keycloak CR.)
