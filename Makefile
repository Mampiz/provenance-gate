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
KYVERNO_VERSION      ?= v1.19.0
KYVERNO_URL          ?= https://github.com/kyverno/kyverno/releases/download/$(KYVERNO_VERSION)/install.yaml
CONTROLLER_GEN_VERSION ?= v0.21.0
GITHUB_OWNER         ?= Mampiz

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
bootstrap: preflight cluster-up cert-manager kyverno policies-audit ## Bring the whole local platform up from zero

.PHONY: verify-f0
verify-f0: ## F0 verifier: local cluster, cert-manager issuing certificates, Go module clean
	@KUBE_CONTEXT=$(KUBE_CONTEXT) ./infra/scripts/verify-f0.sh

##@ F3 - The webhook

IMAGE ?= provenance-gate:dev

.PHONY: manifests
manifests: controller-gen ## Regenerate the CRD and deepcopy code
	./bin/controller-gen object:headerFile=hack/boilerplate.go.txt paths=./api/...
	./bin/controller-gen crd paths=./api/... output:crd:artifacts:config=config/crd

.PHONY: controller-gen
controller-gen: ## Install controller-gen into bin/
	@test -x bin/controller-gen-$(CONTROLLER_GEN_VERSION) || \
		GOBIN=$(PWD)/bin go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_GEN_VERSION)
	@test -x bin/controller-gen-$(CONTROLLER_GEN_VERSION) || \
		mv bin/controller-gen bin/controller-gen-$(CONTROLLER_GEN_VERSION)
	@ln -sf controller-gen-$(CONTROLLER_GEN_VERSION) bin/controller-gen

.PHONY: docker-build
docker-build: ## Build the webhook image
	docker build -t $(IMAGE) \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		--build-arg BUILD_DATE=$(BUILD_DATE) .

.PHONY: kind-load
kind-load: docker-build ## Load the webhook image into the kind cluster
	kind load docker-image $(IMAGE) --name $(CLUSTER_NAME)

.PHONY: deploy
deploy: kind-load ## Deploy the CRD, RBAC, manager and webhook configuration
	$(KUBECTL) apply -k config
	@# The manifest in git carries no meaningful tag, so it is set here rather
	@# than committing something that pretends to be current.
	$(KUBECTL) -n provenance-gate-system set image deployment/provenance-gate manager=$(IMAGE)
	$(KUBECTL) -n provenance-gate-system patch deployment provenance-gate \
		--type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]'
	$(KUBECTL) -n provenance-gate-system rollout status deployment/provenance-gate --timeout=300s

.PHONY: registry-credentials
registry-credentials: ## Give the webhook read access to a private ghcr package (uses $$GITHUB_TOKEN)
	@test -n "$$GITHUB_TOKEN" || { echo "GITHUB_TOKEN is not set"; exit 1; }
	@$(KUBECTL) -n provenance-gate-system create secret generic provenance-gate-registry \
		--from-literal=config.json='{"auths":{"ghcr.io":{"auth":"'"$$(printf '%s' "$(GITHUB_OWNER):$$GITHUB_TOKEN" | base64 -w0)"'"}}}' \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -
	@$(KUBECTL) -n provenance-gate-system rollout restart deployment/provenance-gate
	@$(KUBECTL) -n provenance-gate-system rollout status deployment/provenance-gate --timeout=300s

.PHONY: undeploy
undeploy: ## Remove the webhook and its configuration
	-$(KUBECTL) delete -k config --ignore-not-found

.PHONY: verify-f3
verify-f3: tools ## F3 verifier: the three cases, against real published images
	@KUBE_CONTEXT=$(KUBE_CONTEXT) ./infra/scripts/verify-f3.sh

##@ F2 - Kyverno baseline

.PHONY: kyverno
kyverno: ## Install Kyverno $(KYVERNO_VERSION)
	@# Server-side apply is required, not a preference: the Kyverno CRDs are
	@# larger than the 262144-byte limit on the last-applied-configuration
	@# annotation that a client-side apply writes, and the apply is rejected.
	$(KUBECTL) apply --server-side --force-conflicts -f $(KYVERNO_URL)
	$(KUBECTL) -n kyverno wait deployment --all --for=condition=Available --timeout=300s

.PHONY: policies-audit
policies-audit: ## Apply the baseline corpus in Audit
	$(KUBECTL) apply -k policies/baseline

.PHONY: policies-enforce
policies-enforce: ## Flip the baseline corpus to Deny
	$(KUBECTL) apply -k policies/enforce

.PHONY: verify-f2
verify-f2: tools ## F2 verifier: Audit records, Deny blocks, and the Chainsaw suite passes
	@KUBE_CONTEXT=$(KUBE_CONTEXT) ./infra/scripts/verify-f2.sh

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

.PHONY: lint-shell
lint-shell: tools ## shellcheck every verifier and helper script
	@./bin/shellcheck infra/scripts/*.sh && echo "shellcheck clean"

##@ Housekeeping

.PHONY: clean
clean: ## Remove build output
	rm -rf bin coverage.out
