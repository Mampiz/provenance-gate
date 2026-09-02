# 0006. The baseline corpus uses ValidatingPolicy, not ClusterPolicy

- Status: Accepted
- Date: 2026-09-02

## Context

`ClusterPolicy` is the Kyverno API almost every published example uses, with its
own pattern and anchor syntax. The corpus in `policies/` was written against it
first and worked.

Applying it on Kyverno 1.19 prints:

> ClusterPolicy (kyverno.io) is deprecated and will be removed in a future
> release; migrate to ValidatingPolicy, MutatingPolicy, GeneratingPolicy or
> ImageValidatingPolicy (policies.kyverno.io)

`ValidatingPolicy` is the replacement. It borrows the shape of the upstream
Kubernetes `ValidatingAdmissionPolicy`: `matchConstraints` instead of
match/exclude blocks, CEL expressions instead of patterns, and
`validationActions` instead of a per-rule `failureAction`.

## Decision

Rewrite the corpus as `ValidatingPolicy`.

Not writing new code against a deprecated API is reason enough, but two things
made it better rather than merely newer:

**The rules are more precise in CEL.** `require-image-tag` has to answer
"does this reference carry a tag or a digest". With patterns the available
approximation is `image: "*:*"`, which passes `myregistry:5000/app` because the
registry port supplied a colon. In CEL the expression takes the last path
segment before looking, and the case is simply handled:

```cel
i.contains("@sha256:") || i.split("/")[size(i.split("/")) - 1].contains(":")
```

The pattern version needed a paragraph in the file admitting what it could not
see. That paragraph is gone.

**Audit to Deny becomes one field.** `validationActions` is a single spec-level
list, so `policies/enforce` is a one-line JSON patch targeting every policy by
kind. Under `ClusterPolicy`, `failureAction` sits on each rule, and a JSON patch
addresses rules by index. That forced an artificial "one rule per policy"
constraint on the corpus purely so the overlay could reach every rule, and it
would have broken silently the day somebody added a second rule.

Autogen came free: Kyverno rewrites each policy for Deployments, StatefulSets,
DaemonSets, ReplicaSets, Jobs and CronJobs, adjusting the CEL paths, so a
violation is reported on the Deployment a person edits rather than on a
ReplicaSet they did not create.

## Alternatives considered

**Stay on ClusterPolicy.** Rejected. It works today, and it is the API most
readers recognise, but shipping a supply-chain project built on something that
warns on every apply invites the obvious question and has no good answer.

**Upstream ValidatingAdmissionPolicy, no Kyverno.** Genuinely tempting: these
six rules are all expressible in plain CEL against the built-in API, with no
controller to install. Rejected because Audit mode there produces an audit
annotation on an API server log entry rather than a `PolicyReport` a person can
read with `kubectl`, and the staged rollout the F2 verifier proves is worth more
than one fewer dependency. It is worth revisiting if the corpus stays this
small.

## Consequences

Most Kyverno documentation and examples online are `ClusterPolicy`, so these
files look unfamiliar next to what a reader will find by searching. The comments
carry more weight because of it.

The corpus is now CEL, which is the same language the F3 argument is about. That
is convenient for the argument but does not settle it: the question there is not
whether CEL is expressive, it is what the policy can reach.
