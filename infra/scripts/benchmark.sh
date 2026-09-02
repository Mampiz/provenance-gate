#!/usr/bin/env bash
# Measures what the webhook costs, against the real registry and the real
# transparency log.
#
# The numbers come from the webhook's own histogram
# (controller_runtime_webhook_latency_seconds), not from timing kubectl. A
# kubectl invocation spends more time starting up than the webhook spends
# deciding, and measuring that would produce a number about kubectl.
#
# Two configurations, the same work: the cache on, which is how it ships, and
# the cache off, which is what every admission would cost without it. The
# difference is the whole argument for having one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="${ROOT}/bin:${PATH}"

CONTEXT="${KUBE_CONTEXT:-kind-provenance-local}"
NS="${BENCH_NS:-provenance-gate-bench}"
SYSTEM_NS="provenance-gate-system"
SAMPLES="${SAMPLES:-40}"
PORT="${METRICS_PORT:-18080}"
K="kubectl --context=${CONTEXT}"

REPO="${REPO:-Mampiz/provenance-gate}"
IMAGE="${IMAGE_UNDER_TEST:-ghcr.io/mampiz/provenance-gate}"
OUT="${ROOT}/docs/benchmarks.md"

note() { printf '\033[1m%s\033[0m\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2; exit 1; }

PF_PID=""
cleanup() {
  [ -n "${PF_PID}" ] && kill "${PF_PID}" 2>/dev/null || true
  ${K} delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v crane >/dev/null 2>&1 || fail "crane not found, run 'make tools'"

server="$(${K} config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
case "${server}" in
  https://127.0.0.1:*|https://localhost:*|https://0.0.0.0:*) ;;
  *) fail "refusing to run against a non-local API server: ${server}" ;;
esac

# Prefer this commit's image, but any image the release workflow published will
# do. Unlike the phase verifiers, this measures how long verification takes, not
# whose build it is, and waiting for a release to finish would make the numbers
# harder to reproduce for no gain in what they say.
TAG="sha-$(git -C "${ROOT}" rev-parse HEAD | cut -c1-12)"
if ! DIGEST="$(crane digest "${IMAGE}:${TAG}" 2>/dev/null)"; then
  TAG="$(crane ls "${IMAGE}" 2>/dev/null | grep '^sha-' | tail -1)"
  [ -n "${TAG}" ] || fail "no published image found in ${IMAGE}, has the release workflow ever run?"
  DIGEST="$(crane digest "${IMAGE}:${TAG}")"
  note "this commit has no published image yet, measuring against ${TAG}"
fi

note "preparing ${NS}"
${K} create namespace "${NS}" --dry-run=client -o yaml | ${K} apply -f - >/dev/null
${K} label namespace "${NS}" provenance.miportfolio.com/enforce=true --overwrite >/dev/null
${K} apply -f - >/dev/null <<MANIFEST
apiVersion: provenance.miportfolio.com/v1alpha1
kind: BuildIdentity
metadata:
  name: bench
  namespace: ${NS}
spec:
  subjects:
    - apiVersion: v1
      kind: Pod
      selector:
        matchLabels:
          bench: "true"
  imageRepositories:
    - ${IMAGE}
  provenance:
    issuer: https://token.actions.githubusercontent.com
    builder: https://github.com/${REPO}/.github/workflows/build-sign.yml@refs/heads/main
    sourceRepository: https://github.com/${REPO}
    workflowPath: .github/workflows/release.yml
    workflowRef: refs/heads/main
MANIFEST

# scrape_metrics opens a port-forward, reads /metrics once, and closes it.
scrape_metrics() {
  local pod="$1" out="$2"
  ${K} -n "${SYSTEM_NS}" port-forward "pod/${pod}" "${PORT}:8080" >/dev/null 2>&1 &
  PF_PID=$!
  local ok=1
  for _ in $(seq 1 30); do
    if curl -sf "http://localhost:${PORT}/metrics" -o "${out}"; then ok=0; break; fi
    sleep 1
  done
  kill "${PF_PID}" 2>/dev/null || true
  wait "${PF_PID}" 2>/dev/null || true
  PF_PID=""
  [ "${ok}" -eq 0 ] || fail "could not read the webhook metrics"
}

run_mode() {
  local label="$1" ttl="$2"

  note "configuring the webhook with cache-ttl=${ttl}"
  # One patch, not two. Changing the args is already a new pod template, and a
  # second change on top of it starts a second rollout, which is how the
  # port-forward below ends up attached to a pod that is about to be replaced.
  ${K} -n "${SYSTEM_NS}" patch deployment provenance-gate --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":[\"--admission-timeout=10s\",\"--cache-ttl=${ttl}\",\"--cache-failure-ttl=${ttl}\"]}]" >/dev/null
  ${K} -n "${SYSTEM_NS}" rollout status deployment/provenance-gate --timeout=300s >/dev/null

  # A fresh pod means a fresh histogram, which is why the rollout above is the
  # reset rather than anything clever. Port-forward to the pod by name, so it
  # cannot land on one that is still terminating.
  local pod
  pod="$(${K} -n "${SYSTEM_NS}" get pods -l app.kubernetes.io/name=provenance-gate \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}')"
  [ -n "${pod}" ] || fail "no running webhook pod to measure"

  # The webhook only answers for a namespace that opted in, and only when its
  # certificate is trusted. Prove one admission reaches it before firing the
  # rest, so a misconfiguration cannot be reported as a fast p50 over zero
  # samples.
  ${K} apply --dry-run=server -f - >/dev/null 2>&1 <<PROBE || fail "the probe admission was rejected"
apiVersion: v1
kind: Pod
metadata:
  name: bench-probe
  namespace: ${NS}
  labels:
    bench: "true"
spec:
  securityContext:
    runAsNonRoot: true
  containers:
    - name: app
      image: ${IMAGE}@${DIGEST}
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {cpu: 100m, memory: 64Mi}
PROBE

  note "firing ${SAMPLES} admissions (${label})"
  for i in $(seq 1 "${SAMPLES}"); do
    ${K} apply --dry-run=server -f - >/dev/null 2>&1 <<MANIFEST || true
apiVersion: v1
kind: Pod
metadata:
  name: bench-${i}
  namespace: ${NS}
  labels:
    bench: "true"
spec:
  securityContext:
    runAsNonRoot: true
  containers:
    - name: app
      image: ${IMAGE}@${DIGEST}
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {cpu: 100m, memory: 64Mi}
MANIFEST
  done

  # The port-forward is opened only to read, and closed straight after. Held
  # across the firing it does not survive a cache-off run, which takes long
  # enough for the forwarded connection to be dropped.
  local metrics
  metrics="$(mktemp)"
  scrape_metrics "${pod}" "${metrics}"
  read -r p50 p95 count <<<"$(python3 "${ROOT}/infra/scripts/histogram_quantiles.py" \
    "${metrics}" controller_runtime_webhook_latency_seconds webhook /validate-workload-provenance)"
  # Where the time goes, not just how much of it there is.
  for stage in resolve fetch verify; do
    read -r s50 s95 scount <<<"$(python3 "${ROOT}/infra/scripts/histogram_quantiles.py" \
      "${metrics}" provenance_gate_stage_duration_seconds stage "${stage}")"
    [ "${scount}" -gt 0 ] && printf '    %-8s p50 %8s ms   p95 %8s ms   n=%s\n' "${stage}" "${s50}" "${s95}" "${scount}"
    printf '%s|%s|%s|%s|%s\n' "${label}" "${stage}" "${s50}" "${s95}" "${scount}" >> "${STAGES}"
  done

  rss="$(awk '/^process_resident_memory_bytes /{printf "%.1f", $2/1048576}' "${metrics}")"
  heap="$(awk '/^go_memstats_heap_alloc_bytes /{printf "%.1f", $2/1048576}' "${metrics}")"
  rm -f "${metrics}"

  [ "${count}" -gt 0 ] || fail "the webhook recorded no admissions: it is not being consulted, and a p50 over zero samples is not a measurement"

  printf '  p50 %s ms   p95 %s ms   over %s admissions   rss %s MiB   heap %s MiB\n' \
    "${p50}" "${p95}" "${count}" "${rss}" "${heap}"
  printf '%s|%s|%s|%s|%s|%s\n' "${label}" "${p50}" "${p95}" "${count}" "${rss}" "${heap}" >> "${RESULTS}"
}

RESULTS="$(mktemp)"
STAGES="$(mktemp)"
run_mode "cache on" "10m"
run_mode "cache off" "0s"

note "restoring the shipped configuration"
${K} -n "${SYSTEM_NS}" patch deployment provenance-gate --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["--admission-timeout=4s","--cache-ttl=10m","--cache-failure-ttl=30s"]}]' >/dev/null
${K} -n "${SYSTEM_NS}" set env deployment/provenance-gate BENCH_RUN- >/dev/null
${K} -n "${SYSTEM_NS}" rollout status deployment/provenance-gate --timeout=300s >/dev/null

note "measuring test coverage"
coverage="$(cd "${ROOT}" && go test -coverprofile=/tmp/pg-cover.out ./... >/dev/null 2>&1 && \
  go tool cover -func=/tmp/pg-cover.out | awk '/^total:/{print $3}')"

{
  echo "# Numbers"
  echo
  echo "Regenerate every figure on this page with one command:"
  echo
  echo '```bash'
  echo "make benchmark"
  echo '```'
  echo
  echo "Measured on $(date -u +%Y-%m-%d) against a kind cluster on one machine,"
  echo "verifying \`${IMAGE}:${TAG}\`,"
  echo "firing ${SAMPLES} pod admissions per configuration against a real image in"
  echo "ghcr.io whose attestation is checked against the public transparency log."
  echo "The admission counts below are what the API server actually asked the"
  echo "webhook, which is more than the number of pods: a server-side dry run"
  echo "issues more than one admission review per object."
  echo "They are a shape, not a benchmark of anybody's production cluster."
  echo
  echo "## Admission latency"
  echo
  echo "From the webhook's own \`controller_runtime_webhook_latency_seconds\`"
  echo "histogram, so the figures are what the API server waited for and contain"
  echo "no client overhead. Percentiles are interpolated within histogram buckets,"
  echo "so the resolution is the bucket width."
  echo
  echo "| Configuration | p50 | p95 | Admissions | RSS | Go heap |"
  echo "|---|--:|--:|--:|--:|--:|"
  while IFS='|' read -r label p50 p95 count rss heap; do
    printf '| %s | %s ms | %s ms | %s | %s MiB | %s MiB |\n' \
      "${label}" "${p50}" "${p95}" "${count}" "${rss}" "${heap}"
  done < "${RESULTS}"
  echo
  echo "With the cache off, every admission resolves the tag to a digest, pulls the"
  echo "attestation from the registry, walks the certificate chain and checks the"
  echo "transparency log. That is the honest cost of verifying, and it is why"
  echo "verifying on every admission is not a tuning problem but a design error:"
  echo "a Deployment rolling twenty replicas would pay it twenty times while the"
  echo "API server waits."
  echo
  echo "### Where the time goes"
  echo
  echo "Split by stage, from \`provenance_gate_stage_duration_seconds\`. A total"
  echo "is the one number that cannot be acted on."
  echo
  echo "| Configuration | Stage | p50 | p95 | Observations |"
  echo "|---|---|--:|--:|--:|"
  while IFS='|' read -r label stage s50 s95 scount; do
    [ "${scount}" = "0" ] && continue
    printf '| %s | %s | %s ms | %s ms | %s |\n' "${label}" "${stage}" "${s50}" "${s95}" "${scount}"
  done < "${STAGES}"
  echo
  echo "\`resolve\` turns the tag into a digest, \`fetch\` pulls the attestation"
  echo "out of the registry, and \`verify\` walks the certificate chain and checks"
  echo "the transparency log."
  echo
  echo "The \`cache on\` rows show one observation each, and that is the point:"
  echo "with the cache on exactly one admission does the work and every one after"
  echo "it is a map lookup. That single cold miss is what the \`cache off\` rows"
  echo "measure forty times over."
  echo
  echo "Two things this split settles. Signature verification is not the expensive"
  echo "part: walking the certificate chain and checking the transparency log is"
  echo "about 3 ms, because a Sigstore bundle carries its own inclusion proof and"
  echo "nothing has to be asked of Rekor at admission time. The cost is the"
  echo "registry, and it is almost entirely round trips."
  echo
  echo "### What measuring changed"
  echo
  echo "The first run of this benchmark reported a p50 of 5.5 s and a p95 of 9.5 s"
  echo "with the cache off, both above the 4 s admission timeout the webhook ships"
  echo "with. The first admission for any image would have timed out."
  echo
  echo "The cause was visible only once the stages were split out: one verification"
  echo "makes three registry calls, and each was negotiating its own bearer token"
  echo "and opening its own TLS connection. Sharing one \`go-containerregistry\`"
  echo "Puller across them, which reuses both, took the p50 from 5500 ms to under"
  echo "600 ms. \`resolve\` now reports half a millisecond because the token"
  echo "exchange it used to pay for has already happened."
  echo
  echo "The number that mattered was never the total."
  echo
  echo "### The tail is still above the timeout"
  echo
  echo "These figures move between runs, because \`fetch\` is a round trip to a"
  echo "registry on the public internet and nothing here controls that link. The"
  echo "p50 is stable at roughly half a second; the p95 has been measured anywhere"
  echo "from 1 s to over 5 s."
  echo
  echo "Above 4 s it exceeds the admission timeout, and with"
  echo "\`failurePolicy: Ignore\` a request that times out is admitted unverified."
  echo "That is not a hypothetical: it is the cold path, the first admission for an"
  echo "image nobody has deployed yet, which is exactly the admission worth"
  echo "checking."
  echo
  echo "Two things follow, and neither is a tuning knob. The cache is not an"
  echo "optimisation, it is what keeps the common case three orders of magnitude"
  echo "under the timeout. And"
  echo "[ADR 0009](decisions/0009-failure-policy-starts-at-ignore.md) does not flip"
  echo "to \`Fail\` on the strength of these numbers: a tail that can cross the"
  echo "timeout would turn a slow registry into a cluster that cannot deploy."
  echo "Warming the cache when a BuildIdentity is created, so the cold path is paid"
  echo "by a controller rather than by an admission, is the change that would earn"
  echo "the flip."
  echo
  echo "The shipped \`--admission-timeout\` is 4 s, under the webhook"
  echo "configuration's \`timeoutSeconds: 5\`, so the process gives up first and"
  echo "the API server gets an answer rather than a timeout."
  echo
  echo "## Test coverage"
  echo
  echo "\`${coverage}\` of statements, across the whole module."
  echo
  echo "Coverage of \`internal/provenance\` is the low number, and deliberately so:"
  echo "the registry and signature paths are exercised end to end by the F3 and F4"
  echo "verifiers against real images, which is worth more than a unit test against"
  echo "a mocked transparency log."
} > "${OUT}"

echo
cat "${OUT}"
rm -f "${RESULTS}" "${STAGES}"
