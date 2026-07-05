# syntax=docker/dockerfile:1.7
#
# Thin SecForge derivative of the upstream ONLYOFFICE Docs (Document Server)
# image. Same Document Server; the Ubuntu base + dependency closure are
# apt-upgraded to current security patches AT BUILD TIME, then scanned and
# cosign-signed. The wrapper exists primarily because the cluster's Kyverno
# restrict-image-registries allowlist has no docker.io/onlyoffice entry —
# ghcr.io/jaupole/* + a keyless signature from this repo's workflow is the
# fleet's approved supply chain (same pattern as gotenberg/keycloak).
#
# UPSTREAM PIN: 9.4.0.1 by digest (9.4 removed the Community Edition
# connection limit). Bump = change both lines below + rebuild via
# .github/workflows/onlyoffice-image-build.yml, then re-pin the digest in
# ../09-deployment.yaml.
#
# mirror.gcr.io = Google's transparent Docker Hub pull-through cache
# (identical bytes — the digest below is the Docker Hub manifest digest — and
# no Hub anonymous pull-rate limit on the self-hosted runner; same dodge as
# the gotenberg Dockerfile).
#
# NOTE: no USER change. The DS runs supervisord as root and drops privileges
# per-service itself; forcing non-root here breaks its init. Root-at-runtime
# is handled at the platform layer (PSS baseline namespace + documented
# Kyverno require-run-as-nonroot exemption).

FROM mirror.gcr.io/onlyoffice/documentserver:9.4.0.1@sha256:e3da62a847b9a5d51a11f73cfea1d9c13c3be3809614490d4edddcf01dcf919b

# Patch the Ubuntu base + dependency closure. Entrypoint/cmd/user are
# inherited from the upstream image.
RUN apt-get update \
 && apt-get upgrade -y \
 && rm -rf /var/lib/apt/lists/*
