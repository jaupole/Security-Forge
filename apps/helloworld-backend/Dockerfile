# Multi-stage build for helloworld-backend.
#
# Build context: apps/ (parent dir; apps/lib/ is a replace target).
# build.sh sets the context accordingly.

FROM golang:1.25-alpine AS build
RUN apk add --no-cache ca-certificates
WORKDIR /src

COPY lib/ /src/lib/

COPY helloworld-backend/go.mod helloworld-backend/go.sum /src/helloworld-backend/
WORKDIR /src/helloworld-backend
RUN go mod download -x

COPY helloworld-backend/*.go /src/helloworld-backend/

ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64
RUN go build \
    -trimpath \
    -ldflags "-s -w -buildid= -extldflags=-static" \
    -o /out/helloworld-backend \
    ./

# Merged CA bundle: system + mkcert local root for in-cluster TLS.
COPY helloworld-backend/mkcert-root.pem /tmp/mkcert-root.pem
RUN cat /etc/ssl/certs/ca-certificates.crt /tmp/mkcert-root.pem > /out/ca-bundle.crt

# ─── Runtime ──────────────────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot
USER 65532:65532

COPY --from=build /out/helloworld-backend /helloworld-backend
COPY --from=build /out/ca-bundle.crt      /etc/ssl/certs/ca-certificates.crt

EXPOSE 8080
ENTRYPOINT ["/helloworld-backend"]
