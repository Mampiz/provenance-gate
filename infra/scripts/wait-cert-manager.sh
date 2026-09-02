#!/usr/bin/env bash
# Waits until the cert-manager admission webhook is actually serving.
#
# "kubectl wait deployment --for=condition=Available" is not enough: the
# Deployment reports Available before the webhook Service has endpoints that
# accept connections, and anything creating an Issuer or a Certificate in that
# window fails with
#
#   failed calling webhook "webhook.cert-manager.io": ... connection refused
#
# The only reliable signal is the webhook answering, so this asks it to admit a
# throwaway Issuer with a server-side dry run and waits for that to succeed.
set -euo pipefail

CONTEXT="${KUBE_CONTEXT:-kind-provenance-local}"
TIMEOUT="${TIMEOUT:-180}"
K="kubectl --context=${CONTEXT}"

probe() {
  ${K} apply --dry-run=server -f - >/dev/null 2>&1 <<'MANIFEST'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: webhook-readiness-probe
  namespace: cert-manager
spec:
  selfSigned: {}
MANIFEST
}

printf 'waiting for the cert-manager webhook to admit requests'
deadline=$(( $(date +%s) + TIMEOUT ))
until probe; do
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo
    echo "cert-manager webhook did not start serving within ${TIMEOUT}s" >&2
    ${K} -n cert-manager get pods,endpoints >&2 || true
    exit 1
  fi
  printf '.'
  sleep 2
done
echo " ready"
