# Contributing

## Layout

| | |
|---|---|
| `api/v1alpha1/` | the `BuildIdentity` types. Imports no controller-runtime, so consuming these types does not drag a controller framework in. |
| `internal/provenance/` | resolve, fetch, verify, cache. Knows nothing about admission. |
| `internal/admission/` | the webhook handler. Knows nothing about registries: it takes a `Verifier` interface. |
| `internal/controller/` | reports whether a trust root is usable. |
| `config/` | `default/` is what an install applies, `dev/` points the image at a locally built one. |
| `policies/` | the Kyverno corpus. `baseline/` is Audit, `enforce/` is the same with the action flipped. |
| `tests/policies/` | Chainsaw tests, one directory per policy. |
| `infra/scripts/` | one verifier per phase, plus the waits and the benchmark. |
| `integration/idp-backstage/` | what the IDP has to change. Written out, not applied. |

## Before pushing

```bash
make fmt lint test
make manifests   # then commit the result, CI asserts it is current
make lint-shell
```

CI runs `golangci-lint`, `shellcheck`, the Go tests, and checks that the
committed `controller-gen` output matches the Go types. A CRD that silently lost
a field is not a failure anybody notices.

## Verifiers

A phase is done when its verifier exits 0. Not "done with known limitations".

If a verifier fails, fix the code. Relaxing an assertion to make a phase pass is
the one change that will be rejected on sight, because the verifiers are the only
thing standing between this repository and a README that describes software that
does not work.

Every verifier asserts at least one **rejection**. A test that only walks the
happy path does not show that anything is being verified, and `make verify-f3`
runs its rejection case first for that reason: `failurePolicy: Ignore` means an
unreachable webhook admits everything.

## Decisions

Anything non-obvious gets a numbered record in `docs/decisions/`. Records are
immutable once accepted: a decision that changes gets a new record that
supersedes the old one, and the old one stays with a pointer forward.

[ADR 0002](docs/decisions/0002-own-webhook-alongside-kyverno.md) is wrong and
still in the repository, marked superseded, because the reasoning it contains is
what [ADR 0007](docs/decisions/0007-the-boundary-with-kyverno-was-wrong.md)
argues against. Deleting it would remove the only interesting thing about it.

## Commits

Conventional prefixes, imperative, one line. A body when there is a specific
gotcha worth recording, not as a matter of course.

## Tools

Everything is pinned by version and by SHA-256, and installed into `bin/` by
`make tools`. GitHub Actions are pinned by commit. A supply-chain project that
trusts mutable pointers in its own supply chain is not making an argument.
