# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
#
# Thin SecForge derivative of the upstream Gotenberg image. Same Gotenberg, but
# the Debian base + Chromium/LibreOffice dependency closure are apt-upgraded to
# current security patches AT BUILD TIME, then re-scanned and cosign-signed.
#
# WHY A BUILD, NOT A MIRROR: a pure mirror is upstream's exact bytes and cannot
# be patched. Upstream Gotenberg 8.32/8.33 ship Chromium 147, while Debian
# already packages the fixed Chromium 149 (…-1~deb13u1) plus gnutls/python
# fixes — so `apt-get upgrade` here clears the fixable CRITICALs that a mirror
# would carry. This is how we actually deliver "one image to CVE-patch"
# (ADR-0037), the same pattern as the custom Keycloak image.
#
# Result: ghcr.io/jaupole/gotenberg:<version>-secforge, signed, digest-pinned in
# 09-deployment.yaml.

ARG GOTENBERG_VERSION=8.33.0@sha256:bddd8ea9d076e2d08b6ddaa6efae6403185202c6dab65a6488ed0a6923d6d8e8

# mirror.gcr.io = Google's transparent Docker Hub pull-through cache (identical
# bytes, no Docker Hub anonymous pull-rate limit on the self-hosted runner —
# same dodge as the proposal-forge Dockerfile).
FROM mirror.gcr.io/gotenberg/gotenberg:${GOTENBERG_VERSION}

# Patch the base + Chromium/LibreOffice deps. Needs root; Gotenberg's runtime
# user (UID/GID 1001) is restored afterwards. The entrypoint/cmd are inherited
# from the upstream image (it launches `gotenberg`).
USER root
RUN apt-get update \
 && apt-get upgrade -y \
 && rm -rf /var/lib/apt/lists/*
USER 1001:1001
