# Troubleshooting

The failures you will actually hit, and what each one really means. Every entry
here happened while building this.

## A Deployment sits at zero replicas and says nothing

`kubectl get deployment` shows `0/1` and `kubectl describe deployment` has no
useful event. Admission failures for pods created by a controller are reported
on the **ReplicaSet**, not on the Deployment:

```bash
kubectl -n <namespace> describe replicaset | grep -A5 Events
```

The two usual causes:

```
denied the request: no BuildIdentity in namespace "x" governs Pod "y"
```

The namespace is labelled for enforcement but the workload has no trust root.
Either write one, or take the label off the namespace.

```
denied the request: Policy require-resource-requests-limits failed
```

Kyverno, not this webhook. Both admit the same pods and a workload has to
satisfy both. A `WebApp` needs `security.runAsNonRoot` and `resources` for the
Deployment the operator generates from it to pass the corpus.

## Nothing can be created in a namespace

Check whether the namespace opted in:

```bash
kubectl get namespace <namespace> -o jsonpath='{.metadata.labels}'
```

The webhook only governs namespaces labelled
`provenance.miportfolio.com/enforce=true`, and inside one it refuses anything
with no trust root. Applying the label before writing any `BuildIdentity` gives
exactly this. The trust root goes first.

## Everything is admitted and nothing is being verified

`failurePolicy: Ignore` means an unreachable webhook admits everything, silently.
That is the point of the setting and it is also its cost.

```bash
kubectl -n provenance-gate-system get pods
kubectl get validatingwebhookconfiguration provenance-gate \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | head -c 20
```

An empty `caBundle` means cert-manager did not inject it, and the API server
cannot verify the webhook's certificate. Check the `cert-manager.io/inject-ca-from`
annotation names an existing `Certificate`, and that cert-manager is running.

If you want to be certain the webhook is being consulted, apply something that
must be refused. That is why `make verify-f3` runs its rejection case before its
admission case.

## The webhook crash-loops on start-up

```
building the verifier: fetching the Sigstore trusted root:
mkdir /home/nonroot/.sigstore: read-only file system
```

The Sigstore TUF client defaults its cache to `$HOME/.sigstore`, which does not
exist on a container with a read-only root filesystem. `--tuf-cache-dir` points
it at a mounted volume. The Deployment mounts an `emptyDir` at `/tmp/sigstore`
for exactly this.

## An image is refused and the reason looks wrong

The message names what the provenance actually said:

```
image was built by workflow ".github/workflows/testdata.yml",
but this workload requires ".github/workflows/release.yml"
```

That is the check working. If the image genuinely belongs to this service, the
trust root is wrong, not the image. Check `workflowPath` and `workflowRef`
against what the service's CI really uses. Leaving either empty accepts any
workflow or any branch of the source repository, which is weaker but valid.

```
no SLSA provenance attestation is attached to this image
```

The build did not publish one, or published it without `push-to-registry: true`,
in which case it exists only in the GitHub API and not in the registry. Check
with:

```bash
crane manifest ghcr.io/<owner>/<repo>:sha256-<digest without prefix> | jq '.manifests[].artifactType'
```

## kind will not create a cluster

```
could not find a log line that matches "Reached target .*Multi-User System.*"
```

This message is about neither systemd nor the target it names. The real error is
in the node's own log:

```bash
docker logs <cluster>-control-plane 2>&1 | tail -20
# Failed to create control group inotify object: Too many open files
```

The host is out of inotify instances, so systemd cannot start inside the node and
exits as PID 1. `make preflight` checks this before creating anything and prints
the fix. Every running cluster holds instances, so a limit that was fine for one
cluster fails on the third.

## A policy apply fails with connection refused

```
failed calling webhook "validate-policy.kyverno.svc": connection refused
```

`kubectl wait --for=condition=Available` returns before a webhook Service has
endpoints. `infra/scripts/wait-kyverno.sh` and `wait-cert-manager.sh` wait for
the webhook to actually admit a request, which is a different moment. `make
bootstrap` calls both; a manual `kubectl apply` of Kyverno does not.

## The local cluster runs an old build

`make deploy` builds `provenance-gate:dev` and loads it into kind. The tag does
not change, so Kubernetes sees no reason to restart anything. `make deploy`
forces a rollout for this reason; a bare `kubectl apply -k config/dev` does not,
and the symptom is a controller complaining about fields the CRD does not have.

## The benchmark reports zero admissions

The webhook was not consulted. Usually the benchmark namespace lost its
enforcement label, or the port-forward attached to a pod that was terminating.
`make benchmark` fails loudly on this rather than reporting a fast p50 over zero
samples, which is the one result that would look like good news.
