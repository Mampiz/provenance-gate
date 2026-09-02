# 0005. Publish both a cosign signature and the provenance attestation

- Status: Accepted
- Date: 2026-09-02

## Context

The build already produces a SLSA provenance attestation, signed keyless with
the workflow's OIDC identity. A separate `cosign sign` of the same digest
produces a second Sigstore bundle carrying the same identity and no additional
claim about the artifact. On the face of it, it is redundant.

## Decision

Publish both. `cosign sign --yes <image>@<digest>` runs in the same job as the
provenance attestation, with the same identity.

The redundancy is in the document, not in the ecosystem. What consumes a plain
cosign signature and what consumes an attestation bundle are different tools:

- Kyverno's `verifyImages` and the Sigstore Policy Controller check for a
  signature. This is what F2 and any generic policy engine will look for.
- `gh attestation verify` and the webhook in F3 read the provenance attestation,
  because a signature says only that some identity signed a digest, and the
  question this project asks is which workflow produced it.

Publishing only the attestation would mean the images cannot be checked by the
most widely deployed policy engine in the space. Publishing only the signature
would mean throwing away the only document that names the source.

## Alternatives considered

**Attestation only.** Rejected. Kyverno can read attestations, but the simple,
well-understood `verifyImages` rule that most clusters already run expects a
signature. Being unverifiable by the common tool is a poor argument for a
project whose thesis is about verification.

**Signature only.** Rejected outright. It carries no build identity, which is
the entire subject of this repository.

## Consequences

Three Sigstore bundles hang off every published digest: the signature, the
provenance, and the SBOM. `cosign verify` lists all three, which is a useful
demonstration and worth keeping in the F1 verifier output.

Signing costs one more Rekor entry per build and a few seconds. That is cheap
enough that it does not need defending.

Both documents carry the same identity, so revoking trust in the builder
invalidates both at once. There is no scenario where one is trusted and the
other is not, which is what makes the redundancy safe rather than confusing.
