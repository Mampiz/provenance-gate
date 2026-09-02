#!/usr/bin/env bash
# F1 verifier. Runs against the image actually published to ghcr.io by the
# release workflow, never against a locally built one: the claim being tested is
# about what a consumer can check from the registry, and a local build proves
# nothing about that.
#
# Asserts:
#   1. the tag resolves to a digest, and the digest is a plain image manifest
#   2. gh attestation verify passes for the SLSA provenance
#   3. the signing identity is the REUSABLE workflow, not the caller. This is
#      the Build L3 claim and it is the assertion that would fail first if the
#      build were ever moved inline into a caller
#   4. the provenance predicate names the calling repository, workflow path and
#      ref. F3 matches these against what a resource declares, so if they are
#      not present and correct the whole project has no foundation
#   5. cosign verify passes against the same identity and issuer
#   6. an SBOM attestation exists and is signed by the same identity
#   7. a deliberately wrong expected identity is REJECTED. A verifier that only
#      ever tries the happy path does not show that verification is happening
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="${ROOT}/bin:${PATH}"

REPO="${REPO:-Mampiz/provenance-gate}"
IMAGE="${IMAGE:-ghcr.io/mampiz/provenance-gate}"
OIDC_ISSUER="https://token.actions.githubusercontent.com"
BUILDER_WORKFLOW="${BUILDER_WORKFLOW:-.github/workflows/build-sign.yml}"
BUILDER_REF="${BUILDER_REF:-refs/heads/main}"
BUILDER_IDENTITY="https://github.com/${REPO}/${BUILDER_WORKFLOW}@${BUILDER_REF}"

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
# jq prints the string "null" for a missing key, which is not the same as an
# empty result and would otherwise sail through a plain emptiness check.
require_field() {
  local what="$1" value="$2"
  if [ -z "${value}" ] || [ "${value}" = "null" ]; then
    fail "provenance carries no ${what}"
  fi
}
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

for tool in gh cosign crane jq; do
  command -v "${tool}" >/dev/null 2>&1 || fail "${tool} not found, run 'make tools'"
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

step "1. The published tag resolves to an image manifest"
TAG="${TAG:-sha-$(git -C "${ROOT}" rev-parse HEAD | cut -c1-12)}"
DIGEST="$(crane digest "${IMAGE}:${TAG}" 2>/dev/null)" \
  || fail "cannot resolve ${IMAGE}:${TAG}, has the release workflow run for this commit?"
pass "${IMAGE}:${TAG} resolves to ${DIGEST}"

media="$(crane manifest "${IMAGE}@${DIGEST}" | jq -r '.mediaType // "unknown"')"
case "${media}" in
  application/vnd.oci.image.manifest.v1+json|application/vnd.docker.distribution.manifest.v2+json) ;;
  *) fail "the digest is a ${media}, not an image manifest. BuildKit attestations are probably back on, and a consumer resolving this tag would get an index digest that the attestations do not cover" ;;
esac
pass "the digest is an image manifest (${media})"

step "2. The SLSA provenance attestation verifies"
gh attestation verify "oci://${IMAGE}@${DIGEST}" --repo "${REPO}" \
  --predicate-type "https://slsa.dev/provenance/v1" \
  --format json > "${WORK}/provenance.json" 2>/dev/null \
  || fail "gh attestation verify rejected the provenance attestation"
count="$(jq 'length' "${WORK}/provenance.json")"
[ "${count}" -ge 1 ] || fail "no provenance attestation came back"
pass "gh attestation verify accepted ${count} provenance attestation(s)"

step "3. The signer is the reusable workflow, not the caller"
san="$(jq -r '.[0].verificationResult.signature.certificate.subjectAlternativeName' "${WORK}/provenance.json")"
issuer="$(jq -r '.[0].verificationResult.signature.certificate.issuer' "${WORK}/provenance.json")"
runner="$(jq -r '.[0].verificationResult.signature.certificate.runnerEnvironment' "${WORK}/provenance.json")"
[ "${san}" = "${BUILDER_IDENTITY}" ] \
  || fail "signer identity is '${san}', expected the reusable workflow '${BUILDER_IDENTITY}'"
[ "${issuer}" = "${OIDC_ISSUER}" ] || fail "OIDC issuer is '${issuer}', expected '${OIDC_ISSUER}'"
[ "${runner}" = "github-hosted" ] \
  || fail "runner environment is '${runner}', a self-hosted runner is not a trusted builder here"
pass "signed by ${san}"
pass "issuer ${issuer}, runner ${runner}"

builder="$(jq -r '.[0].verificationResult.statement.predicate.runDetails.builder.id' "${WORK}/provenance.json")"
[ "${builder}" = "${BUILDER_IDENTITY}" ] \
  || fail "predicate builder.id is '${builder}', expected '${BUILDER_IDENTITY}'"
pass "predicate builder.id agrees with the certificate"

step "4. The provenance names the source the artifact came from"
# These three fields are what F3 matches against the build identity declared for
# a resource. Everything the project claims rests on them being here.
wf_repo="$(jq -r '.[0].verificationResult.statement.predicate.buildDefinition.externalParameters.workflow.repository' "${WORK}/provenance.json")"
wf_path="$(jq -r '.[0].verificationResult.statement.predicate.buildDefinition.externalParameters.workflow.path' "${WORK}/provenance.json")"
wf_ref="$(jq -r '.[0].verificationResult.statement.predicate.buildDefinition.externalParameters.workflow.ref' "${WORK}/provenance.json")"
[ "${wf_repo}" = "https://github.com/${REPO}" ] \
  || fail "provenance names repository '${wf_repo}', expected 'https://github.com/${REPO}'"
require_field "workflow path" "${wf_path}"
require_field "workflow ref" "${wf_ref}"
pass "repository ${wf_repo}"
pass "workflow ${wf_path} at ${wf_ref}"

step "5. The cosign keyless signature verifies"
cosign verify \
  --certificate-identity "${BUILDER_IDENTITY}" \
  --certificate-oidc-issuer "${OIDC_ISSUER}" \
  "${IMAGE}@${DIGEST}" > "${WORK}/cosign.json" 2>/dev/null \
  || fail "cosign verify rejected the signature"
jq -e 'any(.[]; .critical.type == "https://sigstore.dev/cosign/sign/v1")' "${WORK}/cosign.json" >/dev/null \
  || fail "cosign verified something, but none of it is a plain signature"
pass "cosign verified the signature against ${BUILDER_IDENTITY}"

step "6. The SBOM is attested by the same identity"
gh attestation verify "oci://${IMAGE}@${DIGEST}" --repo "${REPO}" \
  --predicate-type "https://spdx.dev/Document" \
  --format json > "${WORK}/sbom.json" 2>/dev/null \
  || fail "gh attestation verify found no valid SPDX attestation"
sbom_san="$(jq -r '.[0].verificationResult.signature.certificate.subjectAlternativeName' "${WORK}/sbom.json")"
[ "${sbom_san}" = "${BUILDER_IDENTITY}" ] \
  || fail "the SBOM is signed by '${sbom_san}', not by the builder"
packages="$(jq -r '.[0].verificationResult.statement.predicate.packages | length' "${WORK}/sbom.json" 2>/dev/null || echo 0)"
pass "SPDX attestation signed by the builder, describing ${packages} package(s)"

step "7. A wrong expected identity is rejected"
# Same image, same signature, an identity that is plausible and wrong: the
# caller workflow rather than the builder. Verification has to say no.
if cosign verify \
     --certificate-identity "https://github.com/${REPO}/.github/workflows/release.yml@${BUILDER_REF}" \
     --certificate-oidc-issuer "${OIDC_ISSUER}" \
     "${IMAGE}@${DIGEST}" >/dev/null 2>&1
then
  fail "cosign ACCEPTED a signature under the wrong expected identity, verification is not happening"
fi
pass "cosign rejected the caller workflow as the expected signer"

if gh attestation verify "oci://${IMAGE}@${DIGEST}" --repo "Mampiz/webapp-operator" >/dev/null 2>&1; then
  fail "gh attestation verify ACCEPTED the image as coming from an unrelated repository"
fi
pass "gh attestation verify rejected an unrelated source repository"

printf '\n\033[32m F1 VERIFIER PASSED \033[0m\n'
printf '  image  %s\n  digest %s\n  built by %s\n\n' "${IMAGE}:${TAG}" "${DIGEST}" "${BUILDER_IDENTITY}"
