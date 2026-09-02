# 0009. failurePolicy starts at Ignore, and what it costs

- Status: Accepted
- Date: 2026-09-02

## Context

`failurePolicy` decides what the API server does when it cannot reach this
webhook, or when the webhook does not answer within `timeoutSeconds`.

`Fail` refuses the request. Nothing matching the webhook's rules can be created
while the webhook is unavailable.

`Ignore` admits the request. The workload runs unverified.

They are not two settings of the same dial. They are two different systems: one
where an outage in this component stops deploys everywhere it matches, and one
where an outage in this component silently turns the control off.

## Decision

Ship `Ignore`. Move to `Fail` only once the webhook has an availability record
to justify it, and record that move as its own decision rather than editing this
one.

`Ignore` is the wrong permanent answer. A security control that disables itself
when it breaks is a control an attacker can remove by breaking it, and the
breaking does not have to be sophisticated: enough load to make the webhook miss
its five-second timeout is enough to admit anything. That is the argument for
`Fail`, and it wins in the end.

It does not win yet, because `Fail` has a failure mode that is not recoverable
from inside the cluster. If the webhook is down and its own namespace is within
the webhook's scope, the API server refuses to create the replacement pod,
because creating it requires admission by the webhook that is down. There is no
sequence of `kubectl` commands that fixes this. The only way out is to delete
the ValidatingWebhookConfiguration, which requires someone with cluster-admin
who knows that is the problem.

Two things in `config/webhook/webhook.yaml` exist because of this and are not
optional at either setting:

- a `namespaceSelector` excluding `kube-system`, `provenance-gate-system`,
  `cert-manager` and `kyverno`, so the webhook can never block its own recovery
  or the control plane's;
- `timeoutSeconds: 5`, with the process giving up at four, so the API server
  gets an answer rather than a timeout.

## Alternatives considered

**Ship `Fail` immediately.** The honest security answer, and it is where this
ends up. Rejected for now because "this is the correct posture" is not the same
claim as "this component is reliable enough to hold every deploy hostage", and
only one of those has been demonstrated. F5 measures the latency that decides it.

**Per-namespace policy, `Fail` where it matters and `Ignore` elsewhere.**
Genuinely reasonable and it stays available. Rejected because two
ValidatingWebhookConfigurations differing in one field is a configuration that
drifts, and because a project arguing for verified provenance should not make
enforcement optional per namespace without a much better reason than
convenience.

## Consequences

Until this flips, the webhook is a detection control, not a prevention control,
and the README has to say so rather than implying otherwise.

The flip is a one-field change, and everything that makes it survivable is
already in place. That is the point of doing the `namespaceSelector` and the
timeout now rather than alongside it.

A `Fail` webhook makes this component part of the cluster's control plane in
practice. The Deployment already runs two replicas with a topology spread
constraint, because a single replica means every rolling update is a window in
which nothing can be deployed.
