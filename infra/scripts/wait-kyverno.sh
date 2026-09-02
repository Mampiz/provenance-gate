#!/usr/bin/env bash
# Waits until Kyverno's own policy-validation webhook is actually serving.
#
# The same lesson as wait-cert-manager.sh, and it cost a CI run to learn twice:
# "kubectl wait deployment --for=condition=Available" returns before the
# webhook Service has endpoints that accept connections. Applying a policy in
# that window fails with
#
#   failed calling webhook "validate-policy.kyverno.svc": connection refused
#
# which reads like a broken installation rather than a race. Locally it never
# reproduced, because there is always a minute of doing something else between
# installing Kyverno and applying the first policy.
set -euo pipefail

CONTEXT="${KUBE_CONTEXT:-kind-provenance-local}"
TIMEOUT="${TIMEOUT:-180}"
K="kubectl --context=${CONTEXT}"

probe() {
  ${K} apply --dry-run=server -f - >/dev/null 2>&1 <<'MANIFEST'
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: webhook-readiness-probe
spec:
  validationActions: [Audit]
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE]
        resources: [pods]
  validations:
    - expression: "true"
      message: probe
MANIFEST
}

printf 'waiting for the kyverno policy webhook to admit requests'
deadline=$(( $(date +%s) + TIMEOUT ))
until probe; do
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo
    echo "the kyverno webhook did not start serving within ${TIMEOUT}s" >&2
    ${K} -n kyverno get pods,endpoints >&2 || true
    exit 1
  fi
  printf '.'
  sleep 2
done
echo " ready"
