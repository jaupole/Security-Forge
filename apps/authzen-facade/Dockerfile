# Multi-stage build — no Go install required on the developer machine.
# The build stage downloads the toolchain + modules; the final image
# is distroless (~25 MB) with just the static binary.
#
# Build context is apps/ (parent of authzen-facade/) so the sibling lib/
# is in scope for the local go.mod replace directive that landed in
# Fix-after-07 §A.6.

FROM golang:1.25-alpine AS build

# Build-time deps. We use go modules; CA certs are baked in for module
# downloads over HTTPS.
RUN apk add --no-cache git

WORKDIR /src

# Bring in the shared lib first (replace target).
COPY lib/ /src/lib/

# Deterministic build: go.sum is committed, so we use `go mod download`
# (read-only against the lockfile) instead of `go mod tidy`.
COPY authzen-facade/go.mod authzen-facade/go.sum /src/authzen-facade/
WORKDIR /src/authzen-facade
RUN go mod download -x

COPY authzen-facade/*.go /src/authzen-facade/

# Static, stripped binary.
ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64
RUN go build \
    -trimpath \
    -ldflags "-s -w -buildid= -extldflags=-static" \
    -o /out/authzen-facade \
    ./

# ─── Runtime ──────────────────────────────────────────────────────────
# distroless/static — no shell, no package manager, no /tmp by default.
# Container is unprivileged (UID 65532 'nonroot').

FROM gcr.io/distroless/static-debian12:nonroot

USER 65532:65532

COPY --from=build /out/authzen-facade /authzen-facade

EXPOSE 8080
ENTRYPOINT ["/authzen-facade"]
