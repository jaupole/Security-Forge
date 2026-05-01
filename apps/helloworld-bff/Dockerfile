# Multi-stage build for helloworld-bff.
#
# Build context: apps/ (wider than helloworld-bff/ since Fix-after-07 §A.5
# introduced apps/lib/ as a replace target via local go.mod replace
# directive). build.sh sets the context accordingly. The Dockerfile lives
# at apps/helloworld-bff/Dockerfile but expects the working tree to start
# one level above.
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
#     context at apps/helloworld-bff/mkcert-root.pem before invoking
#     docker build.

FROM golang:1.25-alpine AS build
RUN apk add --no-cache ca-certificates
WORKDIR /src

# Bring in the shared lib first so its go files exist before module
# resolution. The replace directive in helloworld-bff/go.mod points at
# ../lib which resolves to /src/lib once we put helloworld-bff under
# /src/helloworld-bff (matching the apps/ build context layout).
COPY lib/ /src/lib/

# Module fetch + sources for the BFF itself.
COPY helloworld-bff/go.mod helloworld-bff/go.sum /src/helloworld-bff/
WORKDIR /src/helloworld-bff
RUN go mod download -x

COPY helloworld-bff/*.go /src/helloworld-bff/

ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64
RUN go build \
    -trimpath \
    -ldflags "-s -w -buildid= -extldflags=-static" \
    -o /out/helloworld-bff \
    ./

# Build the merged CA bundle: system CAs + mkcert local root.
COPY helloworld-bff/mkcert-root.pem /tmp/mkcert-root.pem
RUN cat /etc/ssl/certs/ca-certificates.crt /tmp/mkcert-root.pem > /out/ca-bundle.crt

# ─── Runtime ──────────────────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot
USER 65532:65532

COPY --from=build /out/helloworld-bff /helloworld-bff
COPY --from=build /out/ca-bundle.crt  /etc/ssl/certs/ca-certificates.crt

EXPOSE 3000
ENTRYPOINT ["/helloworld-bff"]
