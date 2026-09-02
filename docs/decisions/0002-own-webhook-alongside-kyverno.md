# 0002. An admission webhook of our own, alongside Kyverno and not instead of it

- Status: Superseded by [0007](0007-the-boundary-with-kyverno-was-wrong.md)
- Date: 2026-09-02

> **This record is wrong.** Its central claim, that Kyverno cannot express a
> per-resource build identity check, was tested against Kyverno 1.19 and does
> not hold. It is kept unedited because the reasoning it contains is what ADR
> 0007 argues against. See
> [the probe](evidence/kyverno-cel-probe.sh) for how it was disproved.

## Context

Signature verification at admission time is solved. Kyverno has `verifyImages`
with keyless cosign support, and Sigstore ships a Policy Controller that does
little else. Writing a third one would be a toy, and a reviewer would be right
to say so.

The gap is narrower than "verify signatures" and it is worth stating precisely.
Those tools answer:

> is this image signed by an identity on a list I wrote into the policy?

The list lives in the policy. It is static with respect to the workload being
admitted. What this project needs to answer is:

> is this image built by the workflow that belongs to *this specific resource*,
> according to what the platform recorded when it created it?

The expected identity is a property of the object under admission, not of the
policy. `idp-backstage` scaffolds a repository per service and records which one
on the custom resource it applies, as the annotation
`platform.miportfolio.com/source-repository`. A signature that is valid, recent,
and issued to a genuine GitHub Actions workflow of some other repository has to
be rejected, and rejected *because it belongs to another service*.

Expressing that in Kyverno means one policy per service, generated and kept in
sync with the platform, or a CEL expression reaching across the SLSA provenance
predicate and the resource's own annotations. The first does not scale past a
handful of services. The second is writing a program in YAML.

## Decision

Kyverno owns the general policy corpus: mutable tags, `runAsNonRoot`, resource
requests and limits, `privileged`, `hostPath`. Those are cluster-wide rules with
no per-resource parameter and Kyverno expresses them better than any code would.

A webhook of our own owns exactly one thing: matching the build identity carried
by the image's provenance against the build identity declared for that resource.

The boundary is a rule, not a preference. **If a check can be written as a
Kyverno policy without generating one policy per service, it is a Kyverno
policy.** Anything found duplicating Kyverno gets deleted from the webhook.

## Alternatives considered

**Kyverno alone, with a generated policy per service.** Rejected. The number of
policies grows with the number of services, every scaffolded service becomes a
cluster-scoped write, and deleting a service leaves a stale policy that nobody
notices until it blocks something.

**Sigstore Policy Controller alone.** Rejected for the same reason: its
`ClusterImagePolicy` matches on image glob patterns and carries the expected
identity in the policy. There is no way to say "the expected identity is in the
annotation of the object being admitted".

**Kyverno with a CEL expression over the attestation.** The closest option, and
it is genuinely capable. Rejected because the logic in question needs to resolve
a tag to a digest, fetch a referrer, verify a certificate chain against Rekor,
cache the result, and fail with a message a developer can act on. That is a
program. Writing it in Go where it can be unit tested is not a preference, it is
the difference between something that can be shown to work and something that is
believed to work.

## Consequences

The project now has two enforcement points and has to explain both, which is a
documentation cost paid deliberately: "why a webhook and not just Kyverno" is
the question the project exists to answer, so it belongs in the README rather
than being hidden.

The webhook is a hard dependency for the workloads it guards. That is why its
availability posture (`failurePolicy`, `namespaceSelector`, timeout, caching)
gets its own decision record rather than being an implementation detail.

There is a real risk of the webhook accreting general-purpose checks over time
because adding one is easy. The boundary rule above exists to be quoted back at
whoever tries.
