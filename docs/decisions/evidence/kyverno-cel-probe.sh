#!/usr/bin/env bash
# Evidence for ADR 0007.
#
# ADR 0002 claimed Kyverno could not express "the image's provenance must name
# the repository this specific resource declares". This script is how that claim
# was tested, and it is committed so the finding can be reproduced rather than
# taken on trust.
#
# It applies ImageValidatingPolicy objects with --dry-run=server and reports
# whether each CEL expression COMPILES. Kyverno type-checks expressions at
# admission time, so a compile failure names the undeclared reference exactly.
#
# What it establishes: which identifiers exist in the CEL environment of
# spec.validations. What it does NOT establish: runtime behaviour against a real
# image. That needs a publicly pullable image and is covered by the F3 verifier.
set -euo pipefail

CONTEXT="${KUBE_CONTEXT:-kind-provenance-local}"
K="kubectl --context=${CONTEXT}"

probe() {
  local expr="$1"
  local out
  out="$(cat <<YAML | ${K} apply --dry-run=server -f - 2>&1 || true
apiVersion: policies.kyverno.io/v1
kind: ImageValidatingPolicy
metadata:
  name: cel-probe
spec:
  validationActions: [Deny]
  evaluation:
    background:
      enabled: false
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE]
        resources: [pods]
  matchImageReferences:
    - glob: "ghcr.io/*"
  attestors:
    - name: gh
      cosign:
        keyless:
          identities:
            - issuer: https://token.actions.githubusercontent.com
              subject: https://github.com/Mampiz/provenance-gate/.github/workflows/build-sign.yml@refs/heads/main
  attestations:
    - name: provenance
      intoto:
        type: https://slsa.dev/provenance/v1
  validations:
    - expression: ${expr}
      message: probe
YAML
)"
  if printf '%s' "${out}" | grep -q 'created'; then
    printf '  \033[32mCOMPILES  \033[0m %s\n' "${expr}"
  else
    printf '  \033[31mREJECTED  \033[0m %s\n             %s\n' "${expr}" \
      "$(printf '%s' "${out}" | grep -oE "undeclared reference to '[^']*'" | head -1)"
  fi
}

echo
echo "Is the object under admission in scope?"
probe 'object.metadata.name != ""'

echo
echo "Can the attestation predicate be read?"
probe 'images.containers.map(i, extractPayload(i, attestations.provenance)).all(e, e != null)'

echo
echo "The claim ADR 0002 said was out of reach:"
probe 'images.containers.map(i, extractPayload(i, attestations.provenance).predicate.buildDefinition.externalParameters.workflow.repository).all(r, r == object.metadata.annotations["provenance.miportfolio.com/source-repository"])'

echo
echo "Can an unforgeable trust root be read from the cluster instead of an annotation?"
probe 'resource.Get("v1", "configmaps", "kyverno", "trust").metadata.name != ""'

echo
echo "Not available: the cluster context library under its internal name."
probe 'context.GetResource("v1", "configmaps", "kyverno", "trust").metadata.name != ""'
echo
