# 0008. Verify with sigstore-go and go-containerregistry, not cosign's library

- Status: Accepted
- Date: 2026-09-02

## Context

The webhook has to turn an image reference into a verified SLSA provenance
document. That is three separate jobs: resolve a reference to a digest, find the
attestation attached to that digest, and verify the Sigstore bundle it contains.

Three ways to get there:

**`sigstore-go`.** The reference implementation of Sigstore bundle verification,
maintained by the Sigstore project, and what `gh attestation verify` uses. It is
stable and its API is small. It does not know what a container image is: it
verifies a bundle against an artifact digest and an expected identity, and has
no opinion about registries.

**`github.com/sigstore/cosign/v3/pkg/cosign`.** Knows about container images,
registries, attached signatures and attestations, in one package. It is also the
library behind a CLI, and it brings that with it.

**`sigstore-go` combined with `go-containerregistry`.** go-containerregistry
does the registry half: parse a reference, HEAD it for a digest, list referrers,
pull a blob. sigstore-go does the cryptographic half.

## Decision

sigstore-go with go-containerregistry.

The registry half is genuinely small. Resolving a reference and pulling a
referrer is about sixty lines with go-containerregistry, which is a direct
dependency of anything in this space anyway. What is bought for those sixty
lines is that the verification path uses the same library the reference verifier
uses, with nothing between this code and the bundle.

Three specific reasons, in the order they mattered:

**The bundle is what GitHub publishes.** `actions/attest-build-provenance`
pushes a Sigstore bundle as an OCI referrer with artifactType
`application/vnd.dev.sigstore.bundle.v0.3+json`. sigstore-go consumes exactly
that. Going through cosign's library would mean using its attestation
abstraction to arrive at the same bundle.

**Dependency weight on the admission path.** cosign's package pulls in a large
part of a CLI: key management, KMS providers, TSA clients, its own registry
plumbing. Every one of those is code inside a binary that the API server blocks
on, and none of them are used here.

**The failure modes are legible.** sigstore-go's errors say which check failed:
the certificate identity, the transparency log entry, the artifact digest.
Those errors go straight into an admission rejection message, and a developer
reading "signature verification failed: certificate identity" can act on it.

## Alternatives considered

**`pkg/cosign`.** Rejected on dependency weight, not capability. It would work.
If the verification requirements grow to things sigstore-go does not cover, such
as key-based signatures or a private Sigstore deployment with unusual TSA
handling, this is where to look first.

**sigstore-go alone.** Not possible. It has no way to resolve a tag to a digest
or to find a referrer, and both are required. The brief's own framing of this
choice, that sigstore-go is stable but does not cover container images, is
exactly right, and combining it with go-containerregistry is the answer to it.

**Shelling out to the cosign binary.** Rejected. It puts process spawning on the
admission path, turns errors into exit codes and text, and makes the webhook's
behaviour depend on a binary in the image rather than on code that can be tested.

## Consequences

The trusted root is this project's problem. `root.NewLiveTrustedRoot` fetches
the Sigstore TUF repository at start-up and refreshes it in the background. It
is never fetched on the admission path: a webhook that reached out to TUF while
an API request waited would put a third party's availability in front of every
pod being scheduled. It also means the process needs a writable directory for
TUF metadata, which is why the read-only root filesystem has one emptyDir.

Registry credentials are go-containerregistry's default keychain, so a private
registry works by mounting a docker config and setting `DOCKER_CONFIG`. No
credential handling of our own.

The predicate is decoded into a struct with four fields and everything else in
the document is ignored. That is deliberate: a field nobody checks is a field
nobody can rely on, and decoding the whole SLSA schema would suggest otherwise.
