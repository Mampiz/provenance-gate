#!/usr/bin/env bash
# Waits until webapp-operator's admission webhooks are actually serving.
#
# The third time this pattern appears in this repository, and the reason it is a
# script rather than a sleep each time: a Deployment reports Available before its
# webhook Service has endpoints, and the operator's webhooks fail closed, so an
# apply issued in that window is rejected with a connection error that looks like
# the manifest being wrong.
set -euo pipefail

CONTEXT="${KUBE_CONTEXT:-kind-provenance-local}"
TIMEOUT="${TIMEOUT:-180}"
NS="${PROBE_NS:-default}"
K="kubectl --context=${CONTEXT}"

probe() {
  ${K} apply --dry-run=server -f - >/dev/null 2>&1 <<MANIFEST
apiVersion: platform.miportfolio.com/v1
kind: WebApp
metadata:
  name: webhook-readiness-probe
  namespace: ${NS}
spec:
  image: nginxinc/nginx-unprivileged:1.27-alpine
  port: 8080
MANIFEST
}

printf 'waiting for the webapp-operator webhooks to admit requests'
deadline=$(( $(date +%s) + TIMEOUT ))
until probe; do
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo
    echo "the operator webhooks did not start serving within ${TIMEOUT}s" >&2
    ${K} -n webapp-operator-system get pods,endpoints >&2 || true
    exit 1
  fi
  printf '.'
  sleep 2
done
echo " ready"
