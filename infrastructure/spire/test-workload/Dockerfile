# Distroless static build of the SPIFFE test workload (Phase 2.5).
# Build with:
#   docker build -t secforge/spiffe-test:v1 \
#     infrastructure/spire/test-workload
# Docker Desktop's Kubernetes shares the daemon, so the image is immediately
# usable in-cluster with imagePullPolicy: Never.

FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY cmd ./cmd
RUN CGO_ENABLED=0 GOOS=linux GOFLAGS="-trimpath" \
    go build -ldflags="-s -w" -o /out/spiffe-test ./cmd/spiffe-test

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/spiffe-test /spiffe-test
USER 65532:65532
ENTRYPOINT ["/spiffe-test"]
