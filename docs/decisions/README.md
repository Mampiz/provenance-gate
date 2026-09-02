# Architecture decision records

One file per decision that was not obvious, in the order it was taken. A record
is never edited once accepted: if the decision changes, a new record supersedes
it and says so. The point is that somebody reading this repository in a year can
see what the alternatives were and why they lost, not just what the code does.

| ADR | Title | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0002](0002-own-webhook-alongside-kyverno.md) | An admission webhook of our own, alongside Kyverno | Accepted |
| [0003](0003-cert-manager-for-webhook-certificates.md) | cert-manager issues the webhook serving certificate | Accepted |
