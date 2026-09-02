#!/usr/bin/env bash
# F2 verifier. Exit code is the verdict.
#
# Asserts, against the local kind cluster ONLY:
#   1. Kyverno is installed and every controller is Available
#   2. the whole baseline corpus is loaded
#   3. in Audit, a violating pod is ADMITTED and the violation is RECORDED.
#      Audit that silently does nothing is not audit, and the only proof that it
#      is working is a policy report naming the policies that failed
#   4. flipped to Deny, the same pod is REJECTED
#   5. the excluded namespaces are still excluded. A corpus that also blocks
#      kube-system is not a stricter cluster, it is a broken one, and it cannot
#      be fixed from inside
#   6. the Chainsaw suite passes: every policy rejects its bad case AND admits
#      its good one
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="${ROOT}/bin:${PATH}"

CONTEXT="${KUBE_CONTEXT:-kind-provenance-local}"
NS="${PROBE_NS:-provenance-gate-f2}"
K="kubectl --context=${CONTEXT}"

POLICIES=(
  require-image-tag
  disallow-latest-tag
  require-run-as-nonroot
  require-resource-requests-limits
  disallow-privileged-containers
  disallow-host-path
)

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

cleanup() { ${K} delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

for tool in chainsaw jq; do
  command -v "${tool}" >/dev/null 2>&1 || fail "${tool} not found, run 'make tools'"
done

# The pod every phase of this verifier uses. It breaks three policies at once
# (latest tag, no runAsNonRoot, no resources) and satisfies none of them by
# accident, so "admitted" and "rejected" are both unambiguous.
violating_pod() {
  cat <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: ${NS}
spec:
  containers:
    - name: app
      image: nginx:latest
MANIFEST
}

step "1. Kyverno is installed and Available"
${K} get namespace kyverno >/dev/null 2>&1 || fail "the kyverno namespace does not exist, run 'make kyverno'"
${K} -n kyverno wait deployment --all --for=condition=Available --timeout=300s >/dev/null \
  || fail "not every Kyverno controller is Available"
pass "$(${K} -n kyverno get deployment --no-headers | wc -l) Kyverno controllers Available"

step "2. The baseline corpus is loaded"
${K} apply -k "${ROOT}/policies/baseline" >/dev/null 2>&1 \
  || fail "applying policies/baseline failed"
for policy in "${POLICIES[@]}"; do
  ${K} get validatingpolicy "${policy}" >/dev/null 2>&1 \
    || fail "ValidatingPolicy ${policy} is not installed"
  action="$(${K} get validatingpolicy "${policy}" -o jsonpath='{.spec.validationActions[0]}')"
  [ "${action}" = "Audit" ] || fail "${policy} is in ${action}, the baseline must be Audit"
done
pass "${#POLICIES[@]} policies loaded, all in Audit"

step "3. In Audit, the violation is admitted and recorded"
${K} create namespace "${NS}" --dry-run=client -o yaml | ${K} apply -f - >/dev/null
# Kyverno rebuilds its webhook configuration after a policy changes. Applying in
# the gap would be admitted by an empty rule set, which would make step 3 pass
# for the wrong reason and step 4 fail for it.
sleep 6
violating_pod audited | ${K} apply -f - >/dev/null 2>&1 \
  || fail "a violating pod was REJECTED while every policy is in Audit"
pass "the violating pod was admitted"

recorded=""
for _ in $(seq 1 25); do
  recorded="$(${K} -n "${NS}" get policyreport -o json 2>/dev/null \
    | jq -r '[.items[].results[]? | select(.result=="fail") | .policy] | unique | join(" ")')"
  [ -n "${recorded}" ] && [ "${recorded}" != "" ] && break
  sleep 3
done
[ -n "${recorded}" ] || fail "Audit admitted the pod but recorded nothing: no failing policy report appeared"
for expected in disallow-latest-tag require-run-as-nonroot require-resource-requests-limits; do
  case " ${recorded} " in
    *" ${expected} "*) ;;
    *) fail "the policy report does not mention ${expected}, only: ${recorded}" ;;
  esac
done
pass "policy report records the violation: ${recorded}"

step "4. Flipped to Deny, the same pod is rejected"
${K} apply -k "${ROOT}/policies/enforce" >/dev/null 2>&1 \
  || fail "applying policies/enforce failed"
for policy in "${POLICIES[@]}"; do
  action="$(${K} get validatingpolicy "${policy}" -o jsonpath='{.spec.validationActions[0]}')"
  [ "${action}" = "Deny" ] || fail "${policy} is still in ${action} after applying the enforce overlay"
done
sleep 6
if violating_pod enforced | ${K} apply -f - >/dev/null 2>&1; then
  fail "the violating pod was ADMITTED with every policy in Deny"
fi
pass "the violating pod was rejected by admission"

step "5. The excluded namespaces are still excluded"
# A server-side dry run so nothing is created in kube-system, while still going
# through the full admission path.
if ! ${K} -n kube-system apply --dry-run=server -f - >/dev/null 2>&1 <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: exclusion-probe
  namespace: kube-system
spec:
  containers:
    - name: app
      image: nginx:latest
MANIFEST
then
  fail "the same violating pod was rejected in kube-system: the exclusions are not working and cluster components would be blocked"
fi
pass "kube-system is exempt, the control plane cannot be locked out"

step "6. Every policy rejects its bad case and admits its good one"
chainsaw test "${ROOT}/tests/policies" --kube-context "${CONTEXT}" > /tmp/chainsaw-f2.log 2>&1 \
  || { tail -30 /tmp/chainsaw-f2.log >&2; fail "the Chainsaw suite did not pass"; }
summary="$(grep -E '^- (Passed|Failed|Skipped)' /tmp/chainsaw-f2.log | tr '\n' ' ')"
grep -q '^- Failed  tests 0' /tmp/chainsaw-f2.log || fail "Chainsaw reported failures: ${summary}"
grep -q "^- Passed  tests ${#POLICIES[@]}" /tmp/chainsaw-f2.log \
  || fail "expected ${#POLICIES[@]} Chainsaw tests, got: ${summary}"
pass "Chainsaw: ${summary}"

printf '\n\033[32m F2 VERIFIER PASSED \033[0m\n\n'
