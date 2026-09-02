# 0007. The boundary with Kyverno was wrong, and where it actually falls

- Status: Accepted
- Date: 2026-09-02
- Supersedes: [0002](0002-own-webhook-alongside-kyverno.md)

## Context

ADR 0002 drew the line between Kyverno and a webhook of our own like this:

> Kyverno answers "is this image signed by an identity on a list I wrote into
> the policy?". The list lives in the policy and does not vary with the workload
> being admitted. What this project needs is "is this image built by the
> workflow that belongs to **this** resource?"

That claim was tested before writing any of the webhook, and it is false on
Kyverno 1.19. `docs/decisions/evidence/kyverno-cel-probe.sh` reproduces the
test: it applies `ImageValidatingPolicy` objects with a server-side dry run and
reports which CEL expressions Kyverno's type checker accepts.

What the CEL environment of `spec.validations` actually provides:

| Identifier | What it gives |
|---|---|
| `object` | the resource under admission, annotations included |
| `extractPayload(image, attestations.x)` | the in-toto predicate, so the whole SLSA document |
| `verifyImageSignatures`, `verifyAttestationSignatures` | keyless verification against declared attestors |
| `subjectExpression` on a keyless identity | the expected signer, **computed per resource** |
| `resource.Get(apiVersion, resource, ns, name)` | any object in the cluster |
| `globalContext.Get`, `http.Get` | external context |

So this compiles and Kyverno accepts it:

```cel
images.containers.map(i,
  extractPayload(i, attestations.provenance)
    .predicate.buildDefinition.externalParameters.workflow.repository
).all(r, r == object.metadata.annotations["provenance.miportfolio.com/source-repository"])
```

That is the thesis of ADR 0002, expressed in Kyverno, in nine lines of YAML.

Worse for the old boundary: `resource.Get` means Kyverno can also express the
*stronger* version, the one where the expected identity is read from a separate
cluster object instead of an annotation the submitter controls. Kyverno reaches
further than the argument for a custom webhook assumed.

## Decision

Delete the old boundary and state the real one.

**Kyverno is the enforcement point.** Signature verification, predicate
extraction and the per-resource comparison are all done by an
`ImageValidatingPolicy`. Nothing in this repository reimplements any of that.

**What Kyverno cannot do is be the source of truth.** `resource.Get` *reads* a
trust root. It does not create one, does not keep it in step with the platform
that scaffolds services, and does not stop the wrong person from writing to it.
Those are the questions that decide whether the check means anything:

1. **Where does the expected build identity come from?** An annotation on the
   resource is self-asserted. Anyone who can create the workload can write the
   annotation, point it at a repository they own, build a genuinely signed image
   there, and pass. A check whose expected value is supplied by the thing being
   checked is not a check.
2. **Who is allowed to write it?** The trust root has to be a distinct object
   with its own RBAC, writable by the platform that scaffolds services and by
   nobody else, including the owner of the service it describes.
3. **Who keeps it true?** A service is renamed, a repository moves, a default
   branch changes. A stale trust root either blocks a legitimate deploy or, far
   worse, keeps trusting a repository that no longer belongs to that service.

So this project builds the **trust registry**: a `BuildIdentity` custom
resource, the controller that keeps it in step, and the RBAC that makes it
unforgeable. Kyverno consumes it through `resource.Get`.

An admission webhook of our own is still built, but its justification changed
and this record is where that is admitted. It is not there because Kyverno
cannot do the comparison. It is there because a trust registry that nothing
enforces against is a claim rather than a control, and because F5 measures the
same guarantee implemented twice. If it drifts into duplicating verification
logic that the `ImageValidatingPolicy` already performs, that is a defect.

## Alternatives considered

**Drop the webhook entirely and ship only Kyverno policies.** The most honest
reading of the original rule, "if Kyverno does it, remove it". Rejected because
the registry still needs an enforcement path that does not depend on Kyverno
being installed and correctly configured, and because the comparison in F5 is
worth more than the code it costs.

**Keep ADR 0002 and quietly narrow the webhook.** Rejected. The record was
wrong on a checkable fact. Editing it to look less wrong would remove the only
interesting thing about it.

## Consequences

The README cannot claim Kyverno is incapable of this. It has to make the
narrower and more accurate argument: verification is solved, and the unsolved
part is where the expected identity comes from and who is allowed to write it.

The project got smaller and more defensible at the same time. The scope that
disappeared was scope that should never have existed.

The premise was tested before it was built on. That is the actual lesson, and
it is the one worth putting in front of a reader.
