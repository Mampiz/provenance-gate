# Progress

The phase graph, and what each phase has to prove before the next one starts.
A phase is done when its verifier exits 0. There is no "done with known
limitations": a verifier that does not pass means the phase is not done.

| Phase | What it builds | Verifier | State |
|---|---|---|---|
| F0 | Go module, kind cluster, cert-manager, `make bootstrap` | `make verify-f0` | done |
| F1 | Reusable workflow producing SLSA provenance, keyless cosign signature, SBOM | `make verify-f1` | done |
| F2 | Kyverno baseline policy corpus, Audit then Enforce | `make verify-f2` | done |
| F3 | The trust registry, and the webhook that enforces against it | `make verify-f3` | done |
| F4 | Binding a `WebApp` to the workflow the IDP generated for it | `make verify-f4` | done |
| F5 | Admission latency p50/p95 with and without cache, coverage, memory under load | one command reproduces the numbers in the README | in progress |
| F6 | README and the narrative | reviewed by hand | not started |

## The F3 verifier

The three cases, run against images this repository actually publishes. The
third is the one that carries the whole argument:

1. an image signed by the workflow that belongs to this resource, **admitted**
2. an unsigned image, **rejected**
3. an image signed by a different but entirely legitimate workflow, **rejected**

Case 3 is what separates this from "the image is signed by someone at GitHub".
The decoy image is built by the real reusable workflow from a real caller, so
its signature is genuine and its builder is trusted. It is refused because the
caller is not the one the trust root names:

```
image was built by workflow ".github/workflows/testdata.yml",
but this workload requires ".github/workflows/release.yml"
```

The premise this phase was originally built on turned out to be wrong, and
[ADR 0007](docs/decisions/0007-the-boundary-with-kyverno-was-wrong.md) records
that: Kyverno 1.19 can express the comparison. What it cannot do is be the
source of truth, so F3 builds the trust registry and enforces against it.

## F0 notes

- The host needs `fs.inotify.max_user_instances` at 512 or above. Below that,
  systemd inside the kind node cannot allocate its cgroup watcher and exits as
  PID 1, and kind reports a timeout waiting for `Multi-User System` that says
  nothing about inotify. `make preflight` checks it and prints the fix.
