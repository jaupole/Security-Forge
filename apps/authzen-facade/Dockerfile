# Multi-stage build — no Go install required on the developer machine.
# The build stage downloads the toolchain + modules; the final image
# is distroless (~25 MB) with just the static binary.

FROM golang:1.25-alpine AS build

# Build-time deps. We use go modules; CA certs are baked in for module
# downloads over HTTPS.
RUN apk add --no-cache git

WORKDIR /src

# Deterministic build: go.sum is committed, so we use `go mod download`
# (read-only against the lockfile) instead of `go mod tidy` (which would
# re-resolve the graph and silently shift transitive deps on rebuild).
# Source files come AFTER module fetch for layer-cache friendliness.
COPY go.mod go.sum ./
RUN go mod download -x

COPY *.go ./

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
