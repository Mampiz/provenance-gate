# Getting started

Everything runs on one machine, against a local kind cluster. Nothing here
talks to a cluster you did not create: every `kubectl` call pins `--context`,
and every verifier refuses an API server that is not on localhost.

## What you need

- Docker, Go 1.26, `kind`, `kubectl`, `git`
- `gh`, logged in. `make verify-f1` asks the GitHub attestations API about a
  published image.
- The inotify limits kind documents. `make preflight` checks them and prints
  the fix if they are too low.

Everything else, `cosign`, `crane`, `jq`, `chainsaw`, `shellcheck`,
`controller-gen`, `golangci-lint`, is installed into `bin/` at a pinned version
with a pinned checksum by `make tools`.

## From nothing to a working cluster

```bash
make preflight
make bootstrap    # kind + cert-manager + Kyverno + the policy corpus in Audit
make deploy       # build the webhook, load it into kind, install it
```

`make bootstrap` is idempotent. Running it against an existing cluster changes
nothing.

## Proving it works

Each phase has one verifier, and its exit code is the whole verdict. There is no
partial credit and nothing is skipped when a dependency is missing.

```bash
make verify-f0    # the cluster baseline: cert-manager really issues certificates
make verify-f1    # the published image's provenance, signature and SBOM
make verify-f2    # the Kyverno corpus: Audit records, Deny blocks
make verify-f3    # the three admissions
make verify-f4    # the WebApp path, through the real operator
```

`verify-f4` needs the operator:

```bash
make webapp-operator
```

## Guarding a namespace of your own

The webhook governs a namespace only when that namespace opts in, and refuses
anything with no trust root inside one. Both halves matter, and doing them in
the wrong order gives you a namespace where nothing can be created.

```bash
kubectl --context=kind-provenance-local create namespace my-apps

# 1. The trust root FIRST. A workload applied before it has nothing to be
#    verified against and is refused.
kubectl --context=kind-provenance-local apply -f - <<'YAML'
apiVersion: provenance.miportfolio.com/v1alpha1
kind: BuildIdentity
metadata:
  name: my-service
  namespace: my-apps
spec:
  subjects:
    - apiVersion: platform.miportfolio.com/v1
      kind: WebApp
      name: my-service
    - apiVersion: v1
      kind: Pod
      selector:
        matchLabels:
          app: my-service
  imageRepositories:
    - ghcr.io/mampiz/my-service
  provenance:
    issuer: https://token.actions.githubusercontent.com
    builder: https://github.com/Mampiz/provenance-gate/.github/workflows/build-sign.yml@refs/heads/main
    sourceRepository: https://github.com/Mampiz/my-service
    workflowPath: .github/workflows/ci.yml
    workflowRef: refs/heads/main
YAML

# 2. Then turn the webhook on for the namespace.
kubectl --context=kind-provenance-local label namespace my-apps \
  provenance.miportfolio.com/enforce=true
```

Check the trust root is usable before relying on it. A `BuildIdentity` that is
not `Ready` cannot admit anything, and the message says why:

```console
$ kubectl get buildidentity -n my-apps
NAME         SUBJECT   SOURCE                                    READY   AGE
my-service   WebApp    https://github.com/Mampiz/my-service      True    4s
```

## Tearing it down

```bash
make undeploy      # remove the webhook, leave the cluster
make cluster-down  # delete the cluster
```
