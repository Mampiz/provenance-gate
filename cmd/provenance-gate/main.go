// Command provenance-gate is the admission webhook that refuses a workload
// whose images were not built by the identity that workload is allowed to run.
//
// What it does not do is as important as what it does. It does not verify
// signatures that Kyverno's ImageValidatingPolicy already verifies for its own
// policies, and it does not hold the general policy corpus. It owns the trust
// registry and enforcement against it. See docs/decisions/0007.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"os"
	"time"

	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/controller-runtime/pkg/webhook"

	provenancev1alpha1 "github.com/Mampiz/provenance-gate/api/v1alpha1"
	"github.com/Mampiz/provenance-gate/internal/admission"
	"github.com/Mampiz/provenance-gate/internal/controller"
	"github.com/Mampiz/provenance-gate/internal/provenance"
	"github.com/Mampiz/provenance-gate/internal/version"
)

// WebhookPath is where the ValidatingWebhookConfiguration sends admission
// reviews. It is a constant because the manifest and the server have to agree,
// and a mismatch produces a 404 that the API server reports as the webhook
// being unavailable.
const WebhookPath = "/validate-workload-provenance"

var scheme = runtime.NewScheme()

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(provenancev1alpha1.AddToScheme(scheme))
}

type options struct {
	metricsAddr      string
	probeAddr        string
	webhookPort      int
	certDir          string
	cacheTTL         time.Duration
	cacheFailureTTL  time.Duration
	cacheMaxEntries  int
	admissionTimeout time.Duration
	showVersion      bool
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "provenance-gate: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	var opts options
	zapOpts := zap.Options{Development: false}

	flag.StringVar(&opts.metricsAddr, "metrics-bind-address", ":8080",
		"Address the metrics endpoint binds to.")
	flag.StringVar(&opts.probeAddr, "health-probe-bind-address", ":8081",
		"Address the health and readiness probes bind to.")
	flag.IntVar(&opts.webhookPort, "webhook-port", 9443,
		"Port the admission webhook server listens on.")
	flag.StringVar(&opts.certDir, "cert-dir", "/tmp/k8s-webhook-server/serving-certs",
		"Directory holding tls.crt and tls.key, issued by cert-manager.")
	flag.DurationVar(&opts.cacheTTL, "cache-ttl", 10*time.Minute,
		"How long a successful verification is reused. Zero disables the cache.")
	flag.DurationVar(&opts.cacheFailureTTL, "cache-failure-ttl", 30*time.Second,
		"How long a refusal is reused. Deliberately shorter, so an image whose "+
			"attestation has not been pushed yet becomes admissible without waiting out the success TTL.")
	flag.IntVar(&opts.cacheMaxEntries, "cache-max-entries", 4096,
		"Upper bound on cached verifications.")
	flag.DurationVar(&opts.admissionTimeout, "admission-timeout", 4*time.Second,
		"Budget for one admission decision. Must stay below the timeoutSeconds "+
			"in the webhook configuration, so this gives up first and the API "+
			"server gets an answer rather than a timeout.")
	flag.BoolVar(&opts.showVersion, "version", false, "Print the build identity and exit.")
	zapOpts.BindFlags(flag.CommandLine)
	flag.Parse()

	if opts.showVersion {
		fmt.Println(version.String())
		return nil
	}

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&zapOpts)))
	log := ctrl.Log.WithName("setup")
	log.Info("starting", "version", version.String())

	manager, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		Metrics:                server.Options{BindAddress: opts.metricsAddr},
		HealthProbeBindAddress: opts.probeAddr,
		WebhookServer: webhook.NewServer(webhook.Options{
			Port:    opts.webhookPort,
			CertDir: opts.certDir,
			TLSOpts: []func(*tls.Config){
				func(c *tls.Config) { c.MinVersion = tls.VersionTLS13 },
			},
		}),
	})
	if err != nil {
		return fmt.Errorf("building the manager: %w", err)
	}

	// The trusted root is fetched here, at start-up, and never on the admission
	// path. A webhook that reached out to Sigstore's TUF repository while an API
	// request waited would put a third party's availability in front of every
	// pod being scheduled.
	log.Info("fetching the Sigstore trusted root")
	verifier, err := provenance.NewVerifier(provenance.NewRegistry())
	if err != nil {
		return fmt.Errorf("building the verifier: %w", err)
	}
	log.Info("trusted root ready")

	handler := &admission.Handler{
		Client:   manager.GetClient(),
		Verifier: verifier,
		Cache: provenance.NewCache(
			opts.cacheTTL, opts.cacheFailureTTL, opts.cacheMaxEntries),
		Timeout: opts.admissionTimeout,
	}
	manager.GetWebhookServer().Register(WebhookPath, &webhook.Admission{Handler: handler})

	if err := (&controller.BuildIdentityReconciler{
		Client: manager.GetClient(),
		Scheme: manager.GetScheme(),
	}).SetupWithManager(manager); err != nil {
		return fmt.Errorf("setting up the BuildIdentity controller: %w", err)
	}

	if err := manager.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		return fmt.Errorf("adding the health check: %w", err)
	}
	// Readiness is the webhook's own TLS listener, not a ping. The API server
	// fails admission the moment it cannot reach this, so reporting ready before
	// the listener serves would make every admission fail during a rollout.
	if err := manager.AddReadyzCheck("readyz", manager.GetWebhookServer().StartedChecker()); err != nil {
		return fmt.Errorf("adding the readiness check: %w", err)
	}

	log.Info("serving", "webhookPath", WebhookPath, "port", opts.webhookPort,
		"cacheTTL", opts.cacheTTL, "admissionTimeout", opts.admissionTimeout)

	if err := manager.Start(ctrl.SetupSignalHandler()); err != nil && !errors.Is(err, context.Canceled) {
		return fmt.Errorf("running the manager: %w", err)
	}
	return nil
}
