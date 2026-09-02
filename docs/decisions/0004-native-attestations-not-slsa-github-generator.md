# 0004. GitHub's native attestations, not slsa-github-generator

- Status: Accepted
- Date: 2026-09-02

## Context

There are two ways to produce SLSA provenance for a container image built in
GitHub Actions.

`slsa-framework/slsa-github-generator` is the older one and, for a long time,
the only one that reached Build L3. It is a set of reusable workflows that build
the artifact inside a workflow the calling repository does not control and emit
provenance with `buildType`
`https://github.com/slsa-framework/slsa-github-generator/container@v1`, verified
with `slsa-verifier`.

`actions/attest-build-provenance` is GitHub's own. It emits SLSA v1 provenance
with `buildType` `https://actions.github.io/buildtypes/workflow/v1`, signs it
keyless through Fulcio, records it in Rekor, and with `push-to-registry` stores
it as an OCI referrer of the image. It is verified with `gh attestation verify`,
`cosign`, or anything that can read a Sigstore bundle.

Both were on the table. Using both is not an option worth considering: two
provenance documents of different types describing the same artifact is a
question for the consumer, not an answer.

## Decision

`actions/attest-build-provenance`, called from a reusable workflow of ours.

The Build L3 property comes from the reusable workflow, not from which action
emits the document. The OIDC token GitHub issues to a job running in a reusable
workflow carries `job_workflow_ref` pointing at that workflow, so the signing
certificate's SAN identifies the builder rather than the repository being built.
A caller cannot alter its own build steps without altering our repository. That
is the isolation the level is about, and it is available without adopting a
third-party generator.

## Alternatives considered

**slsa-github-generator.** Rejected, for reasons that are about the consumer,
not about the producer:

- It changes how verification works. Its provenance is designed around
  `slsa-verifier` and its own `buildType`. The admission webhook would have to
  parse a predicate shape that GitHub's tooling does not produce, and the
  project would be verifying something a reader cannot reproduce with
  `gh attestation verify`.
- Its container flow duplicates what the native attestation already does. Both
  would attach provenance to the same digest, and a consumer finding two
  referrers has to decide which one is authoritative. There is no good answer.
- It was built when GitHub had no native answer. GitHub now has one, and the
  native path is where the ecosystem is going: Kyverno, the Sigstore Policy
  Controller and `gh` all read Sigstore bundles.

It remains the right choice for a project that needs `buildType`s the native
action does not emit, or that is already invested in `slsa-verifier`. That is
not this project, and the alternative is recorded here rather than silently
skipped.

**Provenance from BuildKit** (`docker/build-push-action` with `provenance:
mode=max`). Rejected, and actively disabled. BuildKit attestations turn the push
into an OCI image index with an extra `unknown/unknown` manifest. The digest the
action returns is then the index digest, while a consumer resolving the tag and
asking the registry for referrers is looking at a different subject. An
admission webhook resolving a tag to a digest would be verifying attestations
attached to something other than what it is about to admit. The workflow sets
`provenance: false` and `sbom: false` for this reason, and the F1 verifier
asserts the published digest is a plain image manifest so that turning them back
on fails loudly.

## Consequences

Verification needs nothing but the registry. Because the attestations are pushed
as referrers, the webhook in F3 does not call the GitHub API on the admission
path, which would put a third-party outage between a pod and being scheduled.

The provenance is tied to GitHub Actions as a build platform. A future builder
elsewhere would emit a different `buildType` and the webhook would need to learn
it. That is accepted: the project is about a specific platform's build identity,
not about being build-platform agnostic.
