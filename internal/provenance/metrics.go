package provenance

import (
	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

// stageDuration answers "where does an admission spend its time".
//
// The total is already in controller-runtime's webhook histogram, and a total
// is exactly the number that cannot be acted on. Splitting it by stage is what
// turned "verification takes five seconds" into "three registry round trips
// each negotiate their own bearer token", which is a fixable statement.
var stageDuration = prometheus.NewHistogramVec(
	prometheus.HistogramOpts{
		Name: "provenance_gate_stage_duration_seconds",
		Help: "Time spent in each stage of verifying one image.",
		// Buckets from a cache hit to well past the admission timeout, because
		// the interesting values span four orders of magnitude.
		Buckets: []float64{0.001, 0.005, 0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 4, 8, 16},
	},
	[]string{"stage"},
)

// verificationResults counts outcomes, so a cluster can alert on refusals
// climbing without parsing admission messages out of logs.
var verificationResults = prometheus.NewCounterVec(
	prometheus.CounterOpts{
		Name: "provenance_gate_verifications_total",
		Help: "Verifications by outcome.",
	},
	[]string{"outcome"},
)

func init() {
	metrics.Registry.MustRegister(stageDuration, verificationResults)
}
