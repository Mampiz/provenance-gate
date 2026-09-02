# provenance-gate

Admission control that ties a Kubernetes workload to the build that produced it.

Not "this image is signed". **This image was built by the workflow that belongs
to this service**, proved against the SLSA provenance attached to the image and
the build identity the platform recorded when it created the resource.

> This repository is being built phase by phase. The narrative README, the
> measured numbers and the demo arrive with F6. [PROGRESS.md](PROGRESS.md) is
> the current state, and it is honest about what does not exist yet.

## The argument

Kyverno verifies cosign signatures. Sigstore's Policy Controller does little
else. Both answer the same question: *is this image signed by an identity on a
list written into the policy?*

The identity is in the policy, and the policy does not vary with the workload it
is admitting. So an image signed by a real GitHub Actions workflow belonging to
a completely different repository satisfies it.

This project answers a narrower question: *is this image built by the workflow
that belongs to **this** resource?* The expected identity comes from the object
under admission, not from the policy.

Kyverno keeps the general policy corpus, because it expresses cluster-wide rules
better than code does. The webhook here owns only what Kyverno cannot say
without generating one policy per service. That boundary is a rule, written down
in [ADR 0002](docs/decisions/0002-own-webhook-alongside-kyverno.md).

## Where it fits

Two projects it plugs into, neither of which it modifies:

- [webapp-operator](https://github.com/Mampiz/webapp-operator), whose `WebApp`
  custom resource is the workload being admitted.
- [idp-backstage](https://github.com/Mampiz/idp-backstage), which scaffolds a
  service, its repository and its CI, and records the repository on the resource
  it applies.

## Running it

```bash
make preflight    # host limits kind needs, checked before anything is created
make bootstrap    # kind cluster + cert-manager, from zero
make verify-f0    # prove that much works
make help         # every target
```

Every `kubectl` call in this repository pins `--context`, and the verifiers
refuse to run against an API server that is not local.

## Decisions

The choices that were not obvious live in
[docs/decisions](docs/decisions/README.md), one file each, with the alternatives
that lost and why.

## License

Apache-2.0. See [LICENSE](LICENSE).
