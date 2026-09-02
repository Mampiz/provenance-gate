#!/usr/bin/env bash
# F4 verifier: the integration with webapp-operator and the IDP.
#
# The claim under test is the one the whole project is for, stated in the terms
# of a real platform: a WebApp custom resource runs only if its image carries
# provenance from the workflow that belongs to that service.
#
#   1. a WebApp whose image was built by the service's own workflow, ADMITTED,
#      and the operator reconciles it into pods that are admitted too
#   2. the same WebApp with an image off Docker Hub, REJECTED
#   3. the same WebApp with a real, correctly signed image from a different
#      workflow, REJECTED
#
# Case 3 is what makes case 2 mean something. Refusing a Docker Hub image on its
# own only shows there is an allowlist of repositories; refusing a genuinely
# signed image from the same trusted builder shows the check is tied to the
# service.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="${ROOT}/bin:${PATH}"

CONTEXT="${KUBE_CONTEXT:-kind-provenance-local}"
NS="${PROBE_NS:-idp-apps}"
SERVICE="${SERVICE:-demo-service}"
K="kubectl --context=${CONTEXT}"

REPO="${REPO:-Mampiz/provenance-gate}"
ISSUER="https://token.actions.githubusercontent.com"
BUILDER="https://github.com/${REPO}/.github/workflows/build-sign.yml@refs/heads/main"
SOURCE_REPO="https://github.com/${REPO}"

SERVICE_IMAGE="${SERVICE_IMAGE:-ghcr.io/mampiz/provenance-gate}"
DECOY_IMAGE="${DECOY_IMAGE:-ghcr.io/mampiz/provenance-gate-decoy}"
DOCKERHUB_IMAGE="${DOCKERHUB_IMAGE:-nginxinc/nginx-unprivileged:1.27-alpine}"

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

cleanup() { ${K} delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

for tool in crane jq; do
  command -v "${tool}" >/dev/null 2>&1 || fail "${tool} not found, run 'make tools'"
done

REJECTION=""
apply_webapp() {
  local image="$1" out
  if out="$(${K} apply -f - 2>&1 <<MANIFEST
apiVersion: platform.miportfolio.com/v1
kind: WebApp
metadata:
  name: ${SERVICE}
  namespace: ${NS}
spec:
  image: ${image}
  replicas: 1
  port: 8080
  # Not decoration. The Deployment the operator generates from this goes
  # through the F2 corpus like anything else, and without these the pods are
  # refused for missing resources and runAsNonRoot. Two controls stacking is
  # the point, and a service has to satisfy both.
  security:
    runAsNonRoot: true
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi
MANIFEST
)"; then
    REJECTION=""
    return 0
  fi
  REJECTION="${out}"
  return 1
}

step "1. The operator and the webhook are both installed"
server="$(${K} config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
case "${server}" in
  https://127.0.0.1:*|https://localhost:*|https://0.0.0.0:*) ;;
  *) fail "refusing to run against a non-local API server: ${server}" ;;
esac
${K} get crd webapps.platform.miportfolio.com >/dev/null 2>&1 \
  || fail "the WebApp CRD is not installed, run 'make webapp-operator'"
${K} -n webapp-operator-system wait deployment/webapp-operator-controller-manager \
  --for=condition=Available --timeout=300s >/dev/null \
  || fail "webapp-operator is not Available"
${K} -n provenance-gate-system wait deployment/provenance-gate \
  --for=condition=Available --timeout=300s >/dev/null \
  || fail "the provenance-gate webhook is not Available"
pass "webapp-operator and provenance-gate are both running"

step "2. The subjects exist in the registry"
service_digest="$(crane digest "${SERVICE_IMAGE}:sha-$(git -C "${ROOT}" rev-parse HEAD | cut -c1-12)" 2>/dev/null || true)"
[ -n "${service_digest}" ] || fail "cannot resolve ${SERVICE_IMAGE} for this commit, has the release workflow run?"
decoy_digest="$(crane digest "${DECOY_IMAGE}:current" 2>/dev/null || true)"
[ -n "${decoy_digest}" ] || fail "cannot resolve ${DECOY_IMAGE}, has the testdata workflow run?"
pass "service image ${SERVICE_IMAGE}@${service_digest}"
pass "decoy image   ${DECOY_IMAGE}@${decoy_digest}"

step "3. The namespace and the trust root the IDP would create"
${K} create namespace "${NS}" --dry-run=client -o yaml | ${K} apply -f - >/dev/null
${K} label namespace "${NS}" provenance.miportfolio.com/enforce=true --overwrite >/dev/null

# Exactly the shape integration/idp-backstage/buildidentity.yaml.tmpl renders.
# One trust root, two subjects: the custom resource a person applies, and the
# pods the operator creates from it.
${K} apply -f - >/dev/null <<MANIFEST
apiVersion: provenance.miportfolio.com/v1alpha1
kind: BuildIdentity
metadata:
  name: ${SERVICE}
  namespace: ${NS}
  labels:
    app.kubernetes.io/managed-by: idp-scaffolder
spec:
  subjects:
    - apiVersion: platform.miportfolio.com/v1
      kind: WebApp
      name: ${SERVICE}
    - apiVersion: v1
      kind: Pod
      selector:
        matchLabels:
          app: ${SERVICE}
  imageRepositories:
    - ${SERVICE_IMAGE}
    - ${DECOY_IMAGE}
  provenance:
    issuer: ${ISSUER}
    builder: ${BUILDER}
    sourceRepository: ${SOURCE_REPO}
    workflowPath: .github/workflows/release.yml
    workflowRef: refs/heads/main
MANIFEST

for _ in $(seq 1 30); do
  ready="$(${K} -n "${NS}" get buildidentity "${SERVICE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [ "${ready}" = "True" ] && break
  sleep 2
done
[ "${ready:-}" = "True" ] || fail "the BuildIdentity never became Ready"
pass "BuildIdentity ${NS}/${SERVICE} is Ready, governing the WebApp and its pods"

step "4. CASE 2: a WebApp running an image off Docker Hub is REJECTED"
# Before the admission case, so an unreachable webhook is caught here rather
# than reported as a pass.
if apply_webapp "${DOCKERHUB_IMAGE}"; then
  fail "a WebApp running an arbitrary Docker Hub image was ADMITTED"
fi
case "${REJECTION}" in
  *"does not cover"*) ;;
  *) fail "rejected, but not because the image is outside this service's repositories: ${REJECTION}" ;;
esac
pass "rejected: $(printf '%s' "${REJECTION}" | tail -c 160)"

step "5. CASE 3: a WebApp running a genuinely signed image from another workflow is REJECTED"
# This is what stops case 2 from being nothing more than a repository allowlist.
if apply_webapp "${DECOY_IMAGE}@${decoy_digest}"; then
  fail "a WebApp running an image built by a different workflow was ADMITTED"
fi
case "${REJECTION}" in
  *"testdata.yml"*|*"workflow"*) ;;
  *) fail "rejected, but not because of the workflow mismatch: ${REJECTION}" ;;
esac
pass "rejected: $(printf '%s' "${REJECTION}" | tail -c 200)"

step "6. CASE 1: the WebApp running its own service's image is ADMITTED"
if ! apply_webapp "${SERVICE_IMAGE}@${service_digest}"; then
  fail "the correctly built WebApp was REJECTED: ${REJECTION}"
fi
pass "WebApp ${NS}/${SERVICE} admitted"

step "7. The operator reconciles it, and the pods it creates are admitted too"
# The point of the second subject. A WebApp that is admitted and then produces
# pods that are refused is not an integration, it is a Deployment stuck at zero
# replicas with the reason buried on a ReplicaSet.
for _ in $(seq 1 60); do
  ${K} -n "${NS}" get deployment "${SERVICE}-deployment" >/dev/null 2>&1 && break
  sleep 2
done
${K} -n "${NS}" get deployment "${SERVICE}-deployment" >/dev/null 2>&1 \
  || fail "the operator never created Deployment ${SERVICE}-deployment"

created=""
for _ in $(seq 1 45); do
  created="$(${K} -n "${NS}" get pods -l "app=${SERVICE}" --no-headers 2>/dev/null | wc -l)"
  [ "${created:-0}" -ge 1 ] && break
  sleep 2
done
if [ "${created:-0}" -lt 1 ]; then
  ${K} -n "${NS}" describe replicaset 2>&1 | grep -A3 'Events:' | tail -4 >&2 || true
  fail "the operator's ReplicaSet created no pods: the webhook refused them"
fi
pass "${created} pod(s) created and admitted from the WebApp"

printf '\n\033[32m F4 VERIFIER PASSED \033[0m\n'
printf '  admitted  WebApp %s running %s\n  rejected  the same WebApp on Docker Hub\n  rejected  the same WebApp on an image from another workflow\n\n' \
  "${SERVICE}" "${SERVICE_IMAGE}"
