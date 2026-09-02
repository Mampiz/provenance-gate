# Numbers

Regenerate every figure on this page with one command:

```bash
make benchmark
```

Measured on 2026-09-02 against a kind cluster on one machine,
verifying `ghcr.io/mampiz/provenance-gate:sha-3de971a22b19`,
firing 40 pod admissions per configuration against a real image in
ghcr.io whose attestation is checked against the public transparency log.
The admission counts below are what the API server actually asked the
webhook, which is more than the number of pods: a server-side dry run
issues more than one admission review per object.
They are a shape, not a benchmark of anybody's production cluster.

## Admission latency

From the webhook's own `controller_runtime_webhook_latency_seconds`
histogram, so the figures are what the API server waited for and contain
no client overhead. Percentiles are interpolated within histogram buckets,
so the resolution is the bucket width.

| Configuration | p50 | p95 | Admissions | RSS | Go heap |
|---|--:|--:|--:|--:|--:|
| cache on | 0.6 ms | 1.0 ms | 41 | 45.9 MiB | 7.1 MiB |
| cache off | 561.5 ms | 976.9 ms | 40 | 49.6 MiB | 6.7 MiB |

With the cache off, every admission resolves the tag to a digest, pulls the
attestation from the registry, walks the certificate chain and checks the
transparency log. That is the honest cost of verifying, and it is why
verifying on every admission is not a tuning problem but a design error:
a Deployment rolling twenty replicas would pay it twenty times while the
API server waits.

### Where the time goes

Split by stage, from `provenance_gate_stage_duration_seconds`. A total
is the one number that cannot be acted on.

| Configuration | Stage | p50 | p95 | Observations |
|---|---|--:|--:|--:|
| cache on | resolve | 0.5 ms | 0.9 ms | 1 |
| cache on | fetch | 1500.0 ms | 1950.0 ms | 1 |
| cache on | verify | 7.5 ms | 9.8 ms | 1 |
| cache off | resolve | 0.5 ms | 0.9 ms | 40 |
| cache off | fetch | 756.4 ms | 987.2 ms | 40 |
| cache off | verify | 3.0 ms | 4.8 ms | 40 |

`resolve` turns the tag into a digest, `fetch` pulls the attestation
out of the registry, and `verify` walks the certificate chain and checks
the transparency log.

The `cache on` rows show one observation each, and that is the point:
with the cache on exactly one admission does the work and every one after
it is a map lookup. That single cold miss is what the `cache off` rows
measure forty times over.

Two things this split settles. Signature verification is not the expensive
part: walking the certificate chain and checking the transparency log is
about 3 ms, because a Sigstore bundle carries its own inclusion proof and
nothing has to be asked of Rekor at admission time. The cost is the
registry, and it is almost entirely round trips.

### What measuring changed

The first run of this benchmark reported a p50 of 5.5 s and a p95 of 9.5 s
with the cache off, both above the 4 s admission timeout the webhook ships
with. The first admission for any image would have timed out.

The cause was visible only once the stages were split out: one verification
makes three registry calls, and each was negotiating its own bearer token
and opening its own TLS connection. Sharing one `go-containerregistry`
Puller across them, which reuses both, took the p50 from 5500 ms to under
600 ms. `resolve` now reports half a millisecond because the token
exchange it used to pay for has already happened.

The number that mattered was never the total.

### The tail is still above the timeout

These figures move between runs, because `fetch` is a round trip to a
registry on the public internet and nothing here controls that link. The
p50 is stable at roughly half a second; the p95 has been measured anywhere
from 1 s to over 5 s.

Above 4 s it exceeds the admission timeout, and with
`failurePolicy: Ignore` a request that times out is admitted unverified.
That is not a hypothetical: it is the cold path, the first admission for an
image nobody has deployed yet, which is exactly the admission worth
checking.

Two things follow, and neither is a tuning knob. The cache is not an
optimisation, it is what keeps the common case three orders of magnitude
under the timeout. And
[ADR 0009](decisions/0009-failure-policy-starts-at-ignore.md) does not flip
to `Fail` on the strength of these numbers: a tail that can cross the
timeout would turn a slow registry into a cluster that cannot deploy.
Warming the cache when a BuildIdentity is created, so the cold path is paid
by a controller rather than by an admission, is the change that would earn
the flip.

The shipped `--admission-timeout` is 4 s, under the webhook
configuration's `timeoutSeconds: 5`, so the process gives up first and
the API server gets an answer rather than a timeout.

## Test coverage

`32.2%` of statements, across the whole module.

Coverage of `internal/provenance` is the low number, and deliberately so:
the registry and signature paths are exercised end to end by the F3 and F4
verifiers against real images, which is worth more than a unit test against
a mocked transparency log.
