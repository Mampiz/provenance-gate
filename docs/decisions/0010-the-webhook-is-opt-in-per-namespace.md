# 0010. The webhook governs a namespace only when that namespace opts in

- Status: Accepted
- Date: 2026-09-02

## Context

The webhook fails closed: a workload with no BuildIdentity governing it is
refused, because a workload nothing vouches for has not been shown to be
trustworthy and admitting it would make the whole thing a suggestion.

Combined with a `namespaceSelector` that only excluded a handful of system
namespaces, that means every namespace in the cluster needs a trust root for
everything it runs.

The consequence was not theoretical. Installing `webapp-operator`, the very
operator this project exists to guard, produced a Deployment stuck at zero
replicas and no obvious reason why. The reason was three levels down, on the
ReplicaSet:

```
Error creating: admission webhook "workloads.provenance.miportfolio.com"
denied the request: no BuildIdentity in namespace "webapp-operator-system"
governs Pod "webapp-operator-controller-manager-...", so there is no trust
root to verify against
```

That is the design working exactly as specified, and the specification was
wrong. Installing anything new would require writing a trust root for it first,
in a namespace that does not exist yet, for an image whose digest nobody knows
in advance. There is no order of operations that makes it work.

## Decision

The `namespaceSelector` matches on a label, `provenance.miportfolio.com/enforce:
"true"`. Inside a labelled namespace nothing changes: no trust root is still a
refusal. Outside one, the webhook does not run at all.

This is a scoped policy, not a softer one, and the distinction matters. Within
scope it is exactly as strict as before. What changed is that scope is now
something a platform decides deliberately, per namespace, rather than something
inflicted on a cluster the moment the webhook is installed.

Two properties come with it that are worth having on their own:

**It can be rolled out.** Label one namespace, watch what breaks, label the
next. Same discipline as the Audit-then-Enforce staging in F2, and for the same
reason: a control that can only be turned on everywhere at once is a control
nobody turns on.

**The decision sits with the right person.** Labelling a namespace is a
cluster-level permission. The owner of a service running inside one cannot
remove the label, so opting in is not something a workload can opt back out of.
That is the same argument as ADR 0007's, one level up: the check must not be
controlled by the thing being checked.

The `NotIn` list for `kube-system`, `provenance-gate-system`, `cert-manager` and
`kyverno` stays, underneath the label. It is now redundant, which is the point:
if one of those were labelled by mistake, the second net catches it, and with
`failurePolicy: Fail` that mistake would otherwise leave the cluster unable to
restart the webhook that is refusing to let it restart.

## Alternatives considered

**Keep governing everything, and add exclusions as they hurt.** Rejected. The
list grows with every component anybody installs, every entry is discovered by
an outage, and the failure is invisible: a ReplicaSet creating no pods says
nothing on the Deployment.

**Treat a missing BuildIdentity as a pass, with a warning.** Rejected. It gives
a cluster-wide default that is safe to install, at the cost of the property the
project exists to demonstrate. Anyone able to create a workload could avoid
verification by not writing a trust root for it, which is not a control.

**An opt-out label instead, governing everything by default.** Rejected for the
same reason as the first alternative: the default applies to namespaces that do
not exist yet, so installing anything means racing to label its namespace before
its pods are created.

## Consequences

A namespace with no label is unguarded, and the README has to say so plainly
rather than implying the cluster is covered. What guards the unlabelled
namespaces is Kyverno's corpus, which is cluster-wide, and the RBAC that decides
who can deploy where.

Every verifier and every example has to label its namespace. The F3 verifier
asserts the label selector is present, because a webhook that quietly went back
to governing everything would pass all three of its cases and then break the
next thing installed.
