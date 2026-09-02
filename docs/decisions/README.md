# Architecture decision records

One file per decision that was not obvious, in the order it was taken. A record
is never edited once accepted: if the decision changes, a new record supersedes
it and says so. The point is that somebody reading this repository in a year can
see what the alternatives were and why they lost, not just what the code does.

| ADR | Title | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0002](0002-own-webhook-alongside-kyverno.md) | An admission webhook of our own, alongside Kyverno | Superseded by 0007 |
| [0003](0003-cert-manager-for-webhook-certificates.md) | cert-manager issues the webhook serving certificate | Accepted |
| [0004](0004-native-attestations-not-slsa-github-generator.md) | GitHub's native attestations, not slsa-github-generator | Accepted |
| [0005](0005-both-a-cosign-signature-and-an-attestation.md) | Publish both a cosign signature and the provenance attestation | Accepted |
| [0006](0006-validatingpolicy-not-clusterpolicy.md) | The baseline corpus uses ValidatingPolicy, not ClusterPolicy | Accepted |
| [0007](0007-the-boundary-with-kyverno-was-wrong.md) | The boundary with Kyverno was wrong, and where it actually falls | Accepted |
| [0008](0008-sigstore-go-with-go-containerregistry.md) | Verify with sigstore-go and go-containerregistry, not cosign's library | Accepted |
| [0009](0009-failure-policy-starts-at-ignore.md) | failurePolicy starts at Ignore, and what it costs | Accepted |
