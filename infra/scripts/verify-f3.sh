#!/usr/bin/env bash
# F3 verifier. Exit code is the verdict.
#
# The three cases, run against the real cluster with real images published to
# ghcr.io by this repository's own workflows:
#
#   1. an image built by the workflow this workload's trust root names,
#      ADMITTED
#   2. an image with no attestation at all, REJECTED
#   3. an image with a perfectly valid attestation, signed by the same trusted
#      builder, produced by a DIFFERENT caller workflow, REJECTED
#
# The third is the one that carries the argument. Its signature is genuine, its
# builder is trusted, its issuer is right, and it is refused because the build
# does not belong to this workload. If it passes, anything with a GitHub
# signature would pass, and the project would be demonstrating nothing.
#
# Case 2 runs before case 1 on purpose. failurePolicy is Ignore, so an
# unreachable webhook admits everything, and a case-1-first ordering would
# report a pass for a webhook that was not running.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="${ROOT}/bin:${PATH}"

CONTEXT="${KUBE_CONTEXT:-kind-provenance-local}"
NS="${PROBE_NS:-provenance-gate-e2e}"
SYSTEM_NS="provenance-gate-system"
K="kubectl --context=${CONTEXT}"

REPO="${REPO:-Mampiz/provenance-gate}"
ISSUER="https://token.actions.githubusercontent.com"
BUILDER="https://github.com/${REPO}/.github/workflows/build-sign.yml@refs/heads/main"
SOURCE_REPO="https://github.com/${REPO}"

GOOD_IMAGE="${GOOD_IMAGE:-ghcr.io/mampiz/provenance-gate}"
UNSIGNED_IMAGE="${UNSIGNED_IMAGE:-ghcr.io/mampiz/provenance-gate-unsigned}"
DECOY_IMAGE="${DECOY_IMAGE:-ghcr.io/mampiz/provenance-gate-decoy}"

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

cleanup() { ${K} delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

for tool in crane jq; do
  command -v "${tool}" >/dev/null 2>&1 || fail "${tool} not found, run 'make tools'"
done

# applyPod returns 0 when the pod is admitted, 1 when it is refused, and writes
# the API server's message to ${REJECTION}.
REJECTION=""
apply_pod() {
  local name="$1" image="$2" labels="${3:-}"
  local out
  if out="$(${K} apply -f - 2>&1 <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NS}
  labels:
    subject: e2e
    ${labels}
spec:
  securityContext:
    runAsNonRoot: true
  containers:
    - name: app
      image: ${image}
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {cpu: 100m, memory: 64Mi}
MANIFEST
)"; then
    REJECTION=""
    return 0
  fi
  REJECTION="${out}"
  return 1
}

step "1. The target is the local kind cluster"
server="$(${K} config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
case "${server}" in
  https://127.0.0.1:*|https://localhost:*|https://0.0.0.0:*) ;;
  *) fail "refusing to run against a non-local API server: ${server}" ;;
esac
pass "API server is local: ${server}"

step "2. The webhook is deployed and serving"
${K} -n "${SYSTEM_NS}" wait deployment/provenance-gate \
  --for=condition=Available --timeout=300s >/dev/null \
  || fail "the provenance-gate deployment is not Available"
ready="$(${K} -n "${SYSTEM_NS}" get deployment/provenance-gate -o jsonpath='{.status.readyReplicas}')"
[ "${ready:-0}" -ge 1 ] || fail "no ready replica"
pass "${ready} replica(s) ready"

ca="$(${K} get validatingwebhookconfiguration provenance-gate \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}')"
[ -n "${ca}" ] || fail "the webhook configuration has an empty caBundle, cert-manager did not inject it"
pass "caBundle injected by cert-manager"

policy="$(${K} get validatingwebhookconfiguration provenance-gate \
  -o jsonpath='{.webhooks[0].failurePolicy}')"
timeout="$(${K} get validatingwebhookconfiguration provenance-gate \
  -o jsonpath='{.webhooks[0].timeoutSeconds}')"
[ "${timeout}" -le 5 ] || fail "timeoutSeconds is ${timeout}, the ceiling is 5"
pass "failurePolicy=${policy}, timeoutSeconds=${timeout}"

# A webhook that matched its own namespace with failurePolicy Fail could not be
# restarted once it went down, and no kubectl command would fix it.
excluded="$(${K} get validatingwebhookconfiguration provenance-gate -o json \
  | jq -r '.webhooks[0].namespaceSelector.matchExpressions[]
           | select(.key=="kubernetes.io/metadata.name" and .operator=="NotIn")
           | .values[]' | tr '\n' ' ')"
for required in kube-system "${SYSTEM_NS}"; do
  case " ${excluded} " in
    *" ${required} "*) ;;
    *) fail "namespace ${required} is not excluded; with failurePolicy Fail the cluster could not recover from this webhook being down" ;;
  esac
done
pass "kube-system and ${SYSTEM_NS} are excluded from the webhook"

optin="$(${K} get validatingwebhookconfiguration provenance-gate -o json \
  | jq -r '.webhooks[0].namespaceSelector.matchLabels["provenance.miportfolio.com/enforce"] // ""')"
[ "${optin}" = "true" ] \
  || fail "the webhook has no opt-in label selector, so it governs every namespace and nothing can be installed without a trust root"
pass "the webhook governs only namespaces labelled provenance.miportfolio.com/enforce=true"

step "3. The subjects exist in the registry"
resolve() {
  crane digest "$1:current" 2>/dev/null || crane digest "$1:latest" 2>/dev/null || true
}
good_digest="$(crane digest "${GOOD_IMAGE}:sha-$(git -C "${ROOT}" rev-parse HEAD | cut -c1-12)" 2>/dev/null || true)"
[ -n "${good_digest}" ] || fail "cannot resolve ${GOOD_IMAGE} for this commit, has the release workflow run?"
unsigned_digest="$(resolve "${UNSIGNED_IMAGE}")"
[ -n "${unsigned_digest}" ] || fail "cannot resolve ${UNSIGNED_IMAGE}, has the testdata workflow run?"
decoy_digest="$(resolve "${DECOY_IMAGE}")"
[ -n "${decoy_digest}" ] || fail "cannot resolve ${DECOY_IMAGE}, has the testdata workflow run?"
pass "signed   ${GOOD_IMAGE}@${good_digest}"
pass "unsigned ${UNSIGNED_IMAGE}@${unsigned_digest}"
pass "decoy    ${DECOY_IMAGE}@${decoy_digest}"

step "4. A trust root that names this repository's release workflow"
${K} create namespace "${NS}" --dry-run=client -o yaml | ${K} apply -f - >/dev/null
# The webhook governs a namespace only when it is labelled. Without this the
# cases below would all be admitted, and the verifier would pass while proving
# nothing.
${K} label namespace "${NS}" provenance.miportfolio.com/enforce=true --overwrite >/dev/null
${K} apply -f - >/dev/null <<MANIFEST
apiVersion: provenance.miportfolio.com/v1alpha1
kind: BuildIdentity
metadata:
  name: e2e
  namespace: ${NS}
spec:
  subject:
    apiVersion: v1
    kind: Pod
    selector:
      matchLabels:
        subject: e2e
  imageRepositories:
    - ${GOOD_IMAGE}
    - ${UNSIGNED_IMAGE}
    - ${DECOY_IMAGE}
  provenance:
    issuer: ${ISSUER}
    builder: ${BUILDER}
    sourceRepository: ${SOURCE_REPO}
    workflowPath: .github/workflows/release.yml
    workflowRef: refs/heads/main
MANIFEST

for _ in $(seq 1 30); do
  ready="$(${K} -n "${NS}" get buildidentity e2e \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [ "${ready}" = "True" ] && break
  sleep 2
done
[ "${ready:-}" = "True" ] || fail "the BuildIdentity never became Ready: $(${K} -n "${NS}" get buildidentity e2e -o jsonpath='{.status.conditions[0].message}' 2>/dev/null)"
pass "BuildIdentity ${NS}/e2e is Ready"

step "5. CASE 2: an image with no attestation is REJECTED"
# Run before case 1: failurePolicy is Ignore, so an unreachable webhook admits
# everything, and this failing is how that is detected.
if apply_pod unsigned "${UNSIGNED_IMAGE}@${unsigned_digest}"; then
  fail "an image with no attestation was ADMITTED; either the webhook is not being consulted or it is not enforcing"
fi
case "${REJECTION}" in
  *"no SLSA provenance"*|*"no provenance attestation"*) ;;
  *) fail "rejected, but not for the right reason: ${REJECTION}" ;;
esac
pass "rejected: $(printf '%s' "${REJECTION}" | tail -c 150)"

step "6. CASE 3: an image signed by another legitimate workflow is REJECTED"
# The signature is genuine. The builder is the same trusted reusable workflow.
# The issuer is right. It is refused because the caller workflow is not the one
# this workload's trust root names. This is the assertion the project exists for.
if apply_pod decoy "${DECOY_IMAGE}@${decoy_digest}"; then
  fail "an image built by a different workflow was ADMITTED; the check is not tied to the resource and the project demonstrates nothing"
fi
case "${REJECTION}" in
  *"testdata.yml"*|*"workflow"*) ;;
  *) fail "rejected, but not because of the workflow mismatch: ${REJECTION}" ;;
esac
pass "rejected: $(printf '%s' "${REJECTION}" | tail -c 200)"

step "7. CASE 1: the image built by the named workflow is ADMITTED"
if ! apply_pod good "${GOOD_IMAGE}@${good_digest}"; then
  fail "the correctly built image was REJECTED: ${REJECTION}"
fi
pass "admitted"

step "8. A workload with no trust root is REJECTED"
# Fail closed. A workload nothing vouches for must not slip through because
# nobody wrote a BuildIdentity for it.
if apply_pod orphan "${GOOD_IMAGE}@${good_digest}" "subject: none"; then
  fail "a workload governed by no BuildIdentity was ADMITTED"
fi
case "${REJECTION}" in
  *"no BuildIdentity"*) ;;
  *) fail "rejected, but not for the missing trust root: ${REJECTION}" ;;
esac
pass "rejected: no trust root governs it"

printf '\n\033[32m F3 VERIFIER PASSED \033[0m\n'
printf '  admitted  %s\n  rejected  %s (no attestation)\n  rejected  %s (built by another workflow)\n\n' \
  "${GOOD_IMAGE}" "${UNSIGNED_IMAGE}" "${DECOY_IMAGE}"
