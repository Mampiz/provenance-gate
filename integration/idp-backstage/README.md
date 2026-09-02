# Wiring this into the IDP

Three changes to [idp-backstage](https://github.com/Mampiz/idp-backstage), none
of which are in this repository because it does not own that one. They are here
so the integration is reviewable before it is applied, and so the F4 verifier can
build exactly the shape they produce.

The F4 verifier does not simulate any of this. It creates the same
`BuildIdentity` these templates render, against images this repository really
publishes, and admits and refuses real `WebApp` resources through the real
operator.

## 1. The scaffolded service builds through the trusted builder

[`ci.yml.tmpl`](ci.yml.tmpl) replaces the `image` job in
`services/scaffolder/internal/template/files/.github/workflows/ci.yml.tmpl`.

The scaffolded workflow currently builds and pushes the image itself. That is a
SLSA Build L2 arrangement: the repository being built controls how it is built.
Calling the reusable workflow instead makes the signing identity the builder
rather than the caller, which is L3, and it is what lets a consumer check *which
workflow* produced an image rather than only that some GitHub workflow did.

## 2. The scaffolder emits a trust root

[`buildidentity.yaml.tmpl`](buildidentity.yaml.tmpl) goes next to
`webapp.yaml.tmpl` in `services/scaffolder/internal/template/files/`, and
`provision.Cluster` applies it the same way it applies the `WebApp`: server-side
apply, field manager `idp-scaffolder`.

The order matters and it is the opposite of the obvious one. **The trust root is
applied before the WebApp.** A WebApp applied first is refused, because no
BuildIdentity governs it yet, and the run ends in exactly the half-finished state
that repository's failure policy exists to avoid. Applying the trust root first
is idempotent and harmless on its own.

## 3. The namespace opts in

`idp-apps` needs the label the webhook selects on:

```bash
kubectl label namespace idp-apps provenance.miportfolio.com/enforce=true
```

This is a one-off, and it belongs with the namespace creation in
`provision.Cluster.ensureNamespace` rather than in a runbook. See
[ADR 0010](../../docs/decisions/0010-the-webhook-is-opt-in-per-namespace.md) for
why the webhook is opt-in per namespace and why the label is a platform
decision rather than a workload one.

## What a service has to declare to pass

Two controls stack on a scaffolded service, and the F4 verifier found this the
hard way. The `WebApp` needs `security.runAsNonRoot` and `resources`, because
the Deployment the operator generates from it goes through the F2 policy corpus
like any other workload. Without them the WebApp is admitted, and then its pods
are refused, which surfaces as a Deployment stuck at zero replicas.

`webapp.yaml.tmpl` should carry both.

## The RBAC that makes it mean anything

Bind `provenance-gate-registrar` to the scaffolder's ServiceAccount, and to
nothing else:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: idp-scaffolder-registrar
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: provenance-gate-registrar
subjects:
  - kind: ServiceAccount
    name: idp-scaffolder
    namespace: idp-system
```

If a service owner can write their own `BuildIdentity`, they can point it at a
repository they control, build a genuinely signed image there, and pass. The
whole argument rests on this binding existing and being narrow.
