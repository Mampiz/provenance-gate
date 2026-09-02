# Architecture

Four pieces, and the interesting part is which one owns what.

## The trusted builder

`.github/workflows/build-sign.yml` is a **reusable** workflow, and that is the
design rather than a convenience. When a service's CI calls it, the OIDC token
GitHub issues to the job carries `job_workflow_ref` pointing at this file. The
signing identity is therefore the builder, not the repository being built, and a
service cannot change how its own artifact is produced without changing this
repository. That separation is what SLSA calls Build L3.

It publishes three things against one digest, all pushed to the registry as OCI
referrers so verification needs nothing but the registry the image came from:

- SLSA provenance, from `actions/attest-build-provenance`
- a keyless cosign signature, for the tools that expect one
- an SBOM from Syft, attested by the same identity

BuildKit's own provenance and SBOM attestations are switched off. With them on,
the push produces an image index, the digest that comes back is the index
digest, and a consumer resolving a tag and asking for referrers is looking at a
different subject than the one the attestations cover.

## The trust registry

`BuildIdentity` is the answer to "what is this workload allowed to run". It
names an issuer, a builder, a source repository, and optionally a workflow path
and ref, plus the image repositories it covers and the workloads it governs.

It is a separate object rather than an annotation on the workload, and that is
the whole argument. An annotation is written by whoever creates the workload, so
an expected value supplied by the thing being checked is not a check. A
`BuildIdentity` is written by the platform: `provenance-gate-registrar` is bound
to the scaffolder's ServiceAccount and to nobody else.

One trust root carries a list of subjects, because one service takes more than
one shape. The `WebApp` a person applies, and the pods `webapp-operator` creates
from it. Both prove the same identity, and two objects would be two places to
keep in step.

A small controller validates each one and reports `Ready`, so a trust root that
could never admit anything says so in `kubectl get` rather than by silently
refusing every deploy.

## The webhook

A `ValidatingAdmissionWebhook` over pods and `WebApp` resources. For each image
a workload declares:

1. **resolve the reference to a digest.** Everything after this point is about
   the digest. A tag is a mutable pointer, and verifying what it points at now
   says nothing about what will be pulled.
2. **check the image is one this trust root covers.** Outside the list it is
   refused, not ignored, so a pod cannot carry an unrelated image alongside its
   own and have the second go unlooked at.
3. **fetch the attestation** from the registry's referrers, filtered by
   predicate type.
4. **verify the bundle** with `sigstore-go`: the certificate chain, the
   transparency log entry, the expected issuer and signer identity, and that the
   attestation is over *this* digest.
5. **compare the predicate** against the trust root: source repository, workflow
   path, workflow ref. Exact comparisons, because prefix matching on a
   repository URL is how `my-service` comes to accept `my-service-evil`.

Results are cached by digest **and identity**, with a shorter TTL for refusals.
The same image is legitimately trusted by one workload and refused for another,
so a cache keyed only by digest would let the first answer the second.

## Four settings that separate a control from an outage

They live in `config/webhook/webhook.yaml`, each with its reasoning next to it:

- a `namespaceSelector` that governs only namespaces labelled
  `provenance.miportfolio.com/enforce=true`, with the system namespaces excluded
  underneath as a second net
- `timeoutSeconds: 5`, with the process giving up at 4 so it answers rather than
  times out
- `failurePolicy: Ignore`, for now, and
  [ADR 0009](decisions/0009-failure-policy-starts-at-ignore.md) on what that
  costs
- a CA bundle injected by cert-manager rather than patched in by the process,
  which would need the webhook's ServiceAccount to hold write access to a
  cluster-scoped admission configuration

## The division of labour with Kyverno

Kyverno holds the general corpus: mutable tags, `runAsNonRoot`, requests and
limits, `privileged`, `hostPath`. Cluster-wide rules with no per-resource
parameter, which it expresses better than code would.

Kyverno 1.19 could also express the per-resource provenance comparison, which an
earlier version of this project claimed it could not. What it cannot do is
create the trust root, keep it in step with the platform, or control who writes
it. See [ADR 0007](decisions/0007-the-boundary-with-kyverno-was-wrong.md).

Both admit the same workloads, and a service has to satisfy both. A `WebApp`
with no `resources` is admitted by this webhook and then produces pods Kyverno
refuses, which surfaces as a Deployment stuck at zero replicas. That is two
controls stacking, and it is worth knowing about before it happens to you.
