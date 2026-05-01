# Multi-stage build for helloworld-bff.
#
# Build determinism:
#   - go.sum is committed; the build uses `go mod download` (read-only against
#     the lockfile) instead of `go mod tidy` (which re-resolves the graph and
#     can silently change a transitive dep on rebuild).
#   - Source files are copied AFTER the module fetch so layer caching
#     keeps subsequent rebuilds fast.
#
# Trust roots:
#   - The runtime image bundles the standard CA set + the mkcert local
#     root CA appended at build time. Reading the system trust store
#     (crypto/x509.SystemCertPool) gives us OpenBao TLS validation against
#     the mkcert-issued cert without any per-process bundle plumbing.
#   - mkcert's rootCA.pem is NOT committed — it's developer-local. The
#     build.sh wrapper copies it from `mkcert -CAROOT` into the build
#     context as ./mkcert-root.pem before invoking docker build.

FROM golang:1.25-alpine AS build
RUN apk add --no-cache ca-certificates
WORKDIR /src

# Module fetch first so this layer is cached across source-only changes.
COPY go.mod go.sum ./
RUN go mod download -x

COPY *.go ./

ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64
RUN go build \
    -trimpath \
    -ldflags "-s -w -buildid= -extldflags=-static" \
    -o /out/helloworld-bff \
    ./

# Build the merged CA bundle: system CAs + mkcert local root.
COPY mkcert-root.pem /tmp/mkcert-root.pem
RUN cat /etc/ssl/certs/ca-certificates.crt /tmp/mkcert-root.pem > /out/ca-bundle.crt

# ─── Runtime ──────────────────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot
USER 65532:65532

COPY --from=build /out/helloworld-bff /helloworld-bff
COPY --from=build /out/ca-bundle.crt  /etc/ssl/certs/ca-certificates.crt

EXPOSE 3000
ENTRYPOINT ["/helloworld-bff"]
