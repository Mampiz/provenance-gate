# provenance-gate. Everything targets the LOCAL kind cluster: every kubectl
# invocation pins --context=$(KUBE_CONTEXT) explicitly, so no target can ever
# act on whatever context happens to be current.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# ---- Pinned versions (reproducibility over freshness) ----------------------
CLUSTER_NAME         ?= provenance-local
KUBE_CONTEXT         ?= kind-$(CLUSTER_NAME)
KIND_CONFIG          ?= infra/kind/provenance-local.yaml
CERT_MANAGER_VERSION ?= v1.21.1
CERT_MANAGER_URL     ?= https://github.com/cert-manager/cert-manager/releases/download/$(CERT_MANAGER_VERSION)/cert-manager.yaml

KUBECTL := kubectl --context=$(KUBE_CONTEXT)

# ---- Build identity --------------------------------------------------------
VERSION    ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT     ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
PKG        := github.com/Mampiz/provenance-gate/internal/version
LDFLAGS    := -X $(PKG).Version=$(VERSION) -X $(PKG).Commit=$(COMMIT) -X $(PKG).BuildDate=$(BUILD_DATE)

##@ General

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	/^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ F0 - Cluster baseline

.PHONY: preflight
preflight: ## Check the host limits kind needs (inotify, Docker)
	@./infra/scripts/preflight.sh

.PHONY: cluster-up
cluster-up: preflight ## Create the local kind cluster (idempotent)
	@if kind get clusters 2>/dev/null | grep -qx "$(CLUSTER_NAME)"; then \
		echo "kind cluster '$(CLUSTER_NAME)' already exists"; \
	else \
		kind create cluster --config $(KIND_CONFIG); \
	fi
	@$(KUBECTL) cluster-info >/dev/null

.PHONY: cluster-down
cluster-down: ## Delete the local kind cluster
	kind delete cluster --name $(CLUSTER_NAME)

.PHONY: cert-manager
cert-manager: ## Install cert-manager (the admission webhook's serving cert comes from it)
	$(KUBECTL) apply -f $(CERT_MANAGER_URL)
	$(KUBECTL) -n cert-manager wait deployment --all --for=condition=Available --timeout=300s
	@# Available is not the same as serving: see the comment in the script.
	@KUBE_CONTEXT=$(KUBE_CONTEXT) ./infra/scripts/wait-cert-manager.sh

.PHONY: bootstrap
bootstrap: preflight cluster-up cert-manager ## Full F0 bring-up from zero

.PHONY: verify-f0
verify-f0: ## F0 verifier: local cluster, cert-manager issuing certificates, Go module clean
	@KUBE_CONTEXT=$(KUBE_CONTEXT) ./infra/scripts/verify-f0.sh

##@ F1 - Signed builds

.PHONY: tools
tools: ## Install cosign, crane and jq into bin/ at pinned versions and checksums
	@./infra/scripts/tools.sh

.PHONY: verify-f1
verify-f1: tools ## F1 verifier: gh attestation verify and cosign verify against the published image
	@./infra/scripts/verify-f1.sh

##@ Go

.PHONY: build
build: ## Build the binary into bin/
	go build -ldflags '$(LDFLAGS)' -o bin/provenance-gate ./cmd/provenance-gate

.PHONY: test
test: ## Run the unit tests
	go test -race -coverprofile=coverage.out ./...

.PHONY: vet
vet: ## go vet
	go vet ./...

.PHONY: fmt
fmt: ## gofmt the tree
	gofmt -w $(shell find . -name '*.go' -not -path './bin/*')

.PHONY: tidy
tidy: ## go mod tidy
	go mod tidy

.PHONY: lint
lint: ## golangci-lint (uses the binary on PATH, or go run as a fallback)
	@if command -v golangci-lint >/dev/null 2>&1; then \
		golangci-lint run ./...; \
	else \
		echo "golangci-lint not on PATH, skipping is not an option: install it or run 'make vet'"; exit 1; \
	fi

##@ Housekeeping

.PHONY: clean
clean: ## Remove build output
	rm -rf bin coverage.out
