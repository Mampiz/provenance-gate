# Progress

The phase graph, and what each phase has to prove before the next one starts.
A phase is done when its verifier exits 0. There is no "done with known
limitations": a verifier that does not pass means the phase is not done.

| Phase | What it builds | Verifier | State |
|---|---|---|---|
| F0 | Go module, kind cluster, cert-manager, `make bootstrap` | `make verify-f0` | done |
| F1 | Reusable workflow producing SLSA provenance, keyless cosign signature, SBOM | `make verify-f1` | in progress |
| F2 | Kyverno baseline policy corpus, Audit then Enforce | Chainsaw suite: each policy rejects its bad case and admits its good one | not started |
| F3 | The admission webhook: digest resolution, keyless verification, provenance matching | envtest plus e2e in kind, three cases | not started |
| F4 | Binding a `WebApp` to the workflow the IDP generated for it | e2e: scaffold, signed build, admitted; foreign image, rejected | not started |
| F5 | Admission latency p50/p95 with and without cache, coverage, memory under load | one command reproduces the numbers in the README | not started |
| F6 | README and the narrative | reviewed by hand | not started |

## F3 verifier, stated up front

The three cases, because the third is the one that carries the whole argument:

1. an image signed by the workflow that belongs to this resource, **admitted**
2. an unsigned image, **rejected**
3. an image signed by a different but entirely legitimate workflow, **rejected**

Case 3 is what separates this from "the image is signed by someone at GitHub".
If it does not pass, F3 is not done.

## F0 notes

- The host needs `fs.inotify.max_user_instances` at 512 or above. Below that,
  systemd inside the kind node cannot allocate its cgroup watcher and exits as
  PID 1, and kind reports a timeout waiting for `Multi-User System` that says
  nothing about inotify. `make preflight` checks it and prints the fix.
