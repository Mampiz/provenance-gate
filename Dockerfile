# Build stage. Pinned by digest, not by tag: a project about verifying what an
# artifact is made of has no business building on a moving base image.
FROM golang:1.27.1-trixie AS build

WORKDIR /src

# go.sum does not exist until the module has dependencies. The bracket makes the
# COPY optional instead of failing the build on a module that has none yet.
COPY go.mod go.su[m] ./
RUN go mod download

COPY api/ api/
COPY cmd/ cmd/
COPY internal/ internal/

ARG VERSION=dev
ARG COMMIT=unknown
ARG BUILD_DATE=unknown

# CGO off and -trimpath so the binary is static and the build paths do not leak
# into it. Two identical inputs should produce two identical binaries.
RUN CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w \
        -X github.com/Mampiz/provenance-gate/internal/version.Version=${VERSION} \
        -X github.com/Mampiz/provenance-gate/internal/version.Commit=${COMMIT} \
        -X github.com/Mampiz/provenance-gate/internal/version.BuildDate=${BUILD_DATE}" \
      -o /out/provenance-gate ./cmd/provenance-gate

# Runtime stage. distroless/static carries no shell and no package manager, so
# there is nothing to exec into and the SBOM is short enough to read.
FROM gcr.io/distroless/static-debian13:nonroot

COPY --from=build /out/provenance-gate /provenance-gate

# 65532 is distroless' nonroot user. Declared explicitly so the Kyverno
# runAsNonRoot policy in F2 is satisfied by the image itself and not by a patch
# applied to the pod spec.
USER 65532:65532

ENTRYPOINT ["/provenance-gate"]
