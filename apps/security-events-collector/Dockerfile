# Multi-stage build for security-events-collector. Mirrors
# apps/helloworld-bff/Dockerfile so the operator-facing build pattern
# is uniform across SecForge first-class apps.
#
# Build context is `apps/` (parent of this dir), same as helloworld-bff,
# because the Go module replaces github.com/secforge/lib with ../lib —
# that path resolves only when the build root is one level above.
#
# Build determinism (same as helloworld-bff):
#   - go.sum is committed; uses `go mod download` (read-only against
#     the lockfile), NOT `go mod tidy`.
#   - Source files copied AFTER module fetch so the layer cache stays warm.

FROM golang:1.25-alpine AS build
RUN apk add --no-cache ca-certificates
WORKDIR /src

# Bring in the shared lib first so its go files exist before module
# resolution (replace directive points at ../lib).
COPY lib/ /src/lib/

COPY security-events-collector/go.mod security-events-collector/go.sum /src/security-events-collector/
WORKDIR /src/security-events-collector
RUN go mod download -x

COPY security-events-collector/*.go /src/security-events-collector/

ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64
RUN go build \
    -trimpath \
    -ldflags "-s -w -buildid= -extldflags=-static" \
    -o /out/security-events-collector \
    ./

# ─── Runtime ──────────────────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot
USER 65532:65532

COPY --from=build /out/security-events-collector /security-events-collector
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

EXPOSE 8080
ENTRYPOINT ["/security-events-collector"]
