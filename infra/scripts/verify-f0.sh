#!/usr/bin/env bash
# F0 verifier. The exit code is the verdict: 0 = the phase passes, non-zero = it
# does not. There is no partial credit and nothing is skipped when a dependency
# is missing.
#
# Asserts, against the local kind cluster ONLY:
#   1. the API server is local and the node is Ready
#   2. every cert-manager component is Available
#   3. the cert-manager webhook admits requests (Available is not serving)
#   4. cert-manager can issue a real certificate end to end
#   5. the CA injector is present, because F3's webhook depends on it to get a
#      caBundle into its ValidatingWebhookConfiguration
#   6. the Go module builds, vets and tests clean
set -euo pipefail

CONTEXT="${KUBE_CONTEXT:-kind-provenance-local}"
NS="${PROBE_NS:-provenance-gate-f0}"
K="kubectl --context=${CONTEXT}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

cleanup() { ${K} delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

step "1. The target is the local kind cluster"
kubectl config get-contexts -o name | grep -qx "${CONTEXT}" \
  || fail "context ${CONTEXT} not found, run 'make cluster-up'"
server="$(${K} config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
case "${server}" in
  https://127.0.0.1:*|https://localhost:*|https://0.0.0.0:*) ;;
  *) fail "refusing to run against a non-local API server: ${server}" ;;
esac
pass "API server is local: ${server}"
${K} wait node --all --for=condition=Ready --timeout=120s >/dev/null \
  || fail "the kind node never became Ready"
pass "$(${K} get nodes --no-headers | wc -l) node(s) Ready"

step "2. cert-manager is installed and Available"
for deployment in cert-manager cert-manager-webhook cert-manager-cainjector; do
  ${K} -n cert-manager get deployment "${deployment}" >/dev/null 2>&1 \
    || fail "deployment ${deployment} not found, run 'make cert-manager'"
  ${K} -n cert-manager wait deployment/"${deployment}" \
    --for=condition=Available --timeout=300s >/dev/null \
    || fail "deployment ${deployment} is not Available"
done
pass "cert-manager, cert-manager-webhook and cert-manager-cainjector are Available"

step "3. The cert-manager webhook admits requests"
KUBE_CONTEXT="${CONTEXT}" "${ROOT}/infra/scripts/wait-cert-manager.sh" \
  || fail "the cert-manager webhook never started serving"
pass "the cert-manager webhook answers admission requests"

step "4. cert-manager issues a real certificate"
# Deployment Available plus a serving webhook still says nothing about the
# controller doing its job. F3 gets its serving certificate this exact way, so
# prove the whole path now rather than discovering it three phases later.
${K} create namespace "${NS}" --dry-run=client -o yaml | ${K} apply -f - >/dev/null
${K} apply -f - >/dev/null <<MANIFEST
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: f0-selfsigned
  namespace: ${NS}
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: f0-probe
  namespace: ${NS}
spec:
  secretName: f0-probe-tls
  dnsNames:
    - provenance-gate-webhook.${NS}.svc
  issuerRef:
    name: f0-selfsigned
    kind: Issuer
MANIFEST
${K} -n "${NS}" wait certificate/f0-probe --for=condition=Ready --timeout=120s >/dev/null \
  || fail "cert-manager did not issue the probe certificate"
${K} -n "${NS}" get secret f0-probe-tls -o jsonpath='{.data.tls\.crt}' | grep -q . \
  || fail "the issued secret carries no tls.crt"
pass "a Certificate reached Ready and its Secret carries tls.crt"

step "5. The CA injector is reconciling"
${K} get crd certificates.cert-manager.io >/dev/null 2>&1 \
  || fail "the cert-manager CRDs are missing"
# F3 annotates its ValidatingWebhookConfiguration with cert-manager.io/inject-ca-from.
# Nothing reads that annotation unless this RBAC exists, and a webhook with an
# empty caBundle fails every admission with a TLS error that looks like a bug in
# the webhook itself.
${K} get clusterrole cert-manager-cainjector >/dev/null 2>&1 \
  || fail "the cainjector ClusterRole is missing, caBundle injection would silently never happen"
pass "cainjector is installed with its ClusterRole"

step "6. The Go module builds and tests clean"
command -v go >/dev/null 2>&1 || fail "go is not on PATH"
(cd "${ROOT}" && go build ./... ) || fail "go build failed"
(cd "${ROOT}" && go vet ./... >/dev/null 2>&1) || fail "go vet reported problems"
(cd "${ROOT}" && go test ./... >/dev/null) || fail "go test failed"
pass "go build, go vet and go test all pass"

printf '\n\033[32m F0 VERIFIER PASSED \033[0m\n\n'
