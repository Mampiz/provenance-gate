# 0003. cert-manager issues the webhook serving certificate

- Status: Accepted
- Date: 2026-09-02

## Context

A `ValidatingAdmissionWebhook` is called by the API server over TLS. It needs a
serving certificate whose SAN matches its in-cluster Service name, and the
`ValidatingWebhookConfiguration` needs the issuing CA in its `caBundle`. If the
two do not agree, every admission fails with a TLS error that names neither the
certificate nor the bundle, and the symptom looks like the webhook being down.

There are three usual ways to get there: generate a self-signed certificate at
start-up and patch the configuration from inside the process, use the Kubernetes
CertificateSigningRequest API, or let cert-manager issue it and inject the CA.

## Decision

cert-manager, using a self-signed `Issuer`, a `Certificate` for the webhook
Service, and the `cert-manager.io/inject-ca-from` annotation on the
`ValidatingWebhookConfiguration`.

It is installed in F0, before there is anything to secure, and the F0 verifier
proves the whole path works by issuing a real certificate and checking that the
resulting Secret carries a `tls.crt`. Discovering that certificate issuance does
not work while debugging admission logic in F3 would mean debugging two things
at once.

## Alternatives considered

**Self-signed at start-up, patching the webhook configuration from the process.**
Rejected. It needs the webhook's ServiceAccount to hold write access to a
cluster-scoped admission configuration, which is a large permission for a
component whose whole purpose is to be trusted. It also makes certificate
rotation the process's problem, and multiple replicas have to agree on one CA.

**The CertificateSigningRequest API.** Rejected. Approval is a manual step or
another controller, so it is cert-manager with extra work.

**No TLS.** Not possible: the API server does not call webhooks over plaintext.

## Consequences

cert-manager is a hard prerequisite of the cluster, which is why `bootstrap`
installs it and the verifier fails without it rather than degrading.

The verifier waits for the cert-manager webhook to *admit a request* rather than
for its Deployment to report Available. Those are different moments, and a
manifest applied in the gap between them fails with `connection refused`. This
is an assertion added to the verifier, never a `sleep`.

Rotation is cert-manager's job. The webhook reads its certificate from a mounted
Secret and has to pick up changes without a restart, which is a requirement on
the F3 implementation recorded here so it is not forgotten.
