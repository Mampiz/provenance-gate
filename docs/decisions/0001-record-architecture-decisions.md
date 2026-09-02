# 0001. Record architecture decisions

- Status: Accepted
- Date: 2026-09-02

## Context

This project exists to argue a position: that verifying *who built an artifact
and from where* belongs at admission time, and that the existing tools stop just
short of expressing it. An argument is only worth anything if the reasoning
behind each step is visible and can be attacked.

Two of the choices ahead are known to be contentious before a line of them is
written. Whether to build a webhook at all when Kyverno exists. Which library to
verify signatures with, when the obviously named one does not cover container
images. Both deserve to be written down where a reviewer can disagree with them.

## Decision

Every non-obvious decision gets a numbered file in `docs/decisions/`, in a short
form: context, the decision, the alternatives that lost and why, and the
consequences including the ones that hurt.

Records are immutable once accepted. A decision that changes gets a new record
that supersedes the old one, and the old one stays in the repository with a
pointer forward. Deleting a record would hide exactly the thing this directory
exists to preserve.

## Consequences

Some records will read as obvious in hindsight. That is the acceptable cost of
not having to reconstruct, months later, why a working piece of the system is
shaped the way it is.

This is not the same thing as the product documentation. `docs/decisions/`
answers "why is it like this", the README answers "what does this demonstrate".
