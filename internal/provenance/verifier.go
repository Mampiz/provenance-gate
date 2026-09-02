package provenance

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/sigstore/sigstore-go/pkg/bundle"
	"github.com/sigstore/sigstore-go/pkg/root"
	"github.com/sigstore/sigstore-go/pkg/tuf"
	sigverify "github.com/sigstore/sigstore-go/pkg/verify"
)

// Result is a successful verification.
type Result struct {
	// Digest the image reference resolved to. Everything was verified about
	// this, not about whatever tag was asked for.
	Digest string
	// Observed is what the provenance said.
	Observed Observed
}

// Verifier checks that an image was built by the identity a workload declares.
type Verifier struct {
	registry *Registry
	trust    root.TrustedMaterial
}

// NewVerifier builds a Verifier with a trusted root fetched from the Sigstore
// TUF repository.
//
// The root is fetched once here and kept, never on the admission path. A
// verifier that reached out to TUF while an API request waited would put a
// third party's availability in front of every pod being scheduled. LiveTrustedRoot
// refreshes itself in the background, so expiry is handled without that.
func NewVerifier(registry *Registry) (*Verifier, error) {
	opts := tuf.DefaultOptions()
	trusted, err := root.NewLiveTrustedRoot(opts)
	if err != nil {
		return nil, fmt.Errorf("fetching the Sigstore trusted root: %w", err)
	}
	return &Verifier{registry: registry, trust: trusted}, nil
}

// NewVerifierWithTrust builds a Verifier over an already loaded trusted root.
// Tests use it to avoid reaching the network.
func NewVerifierWithTrust(registry *Registry, trusted root.TrustedMaterial) *Verifier {
	return &Verifier{registry: registry, trust: trusted}
}

// Verify resolves the image to a digest and checks that a SLSA provenance
// attestation over that digest was produced by the given identity.
//
// It fails closed. Every path that does not end in a verified attestation whose
// contents match returns an error, including the ones that look like
// infrastructure problems: an image whose attestations cannot be fetched is not
// an image that has been shown to be trustworthy.
func (v *Verifier) Verify(ctx context.Context, imageRef string, want Identity) (Result, error) {
	if err := want.Validate(); err != nil {
		return Result{}, err
	}

	digest, err := v.registry.Resolve(ctx, imageRef)
	if err != nil {
		return Result{}, err
	}

	bundles, err := v.registry.FetchAttestations(ctx, digest, SLSAProvenancePredicateType)
	if err != nil {
		return Result{}, err
	}

	certID, err := sigverify.NewShortCertificateIdentity(want.Issuer, "", want.Builder, "")
	if err != nil {
		return Result{}, fmt.Errorf("building the expected signer identity: %w", err)
	}

	verifier, err := sigverify.NewSignedEntityVerifier(v.trust,
		// The attestation must be in the transparency log, and its timestamp
		// must be observed by at least one source. Both are what make a
		// signature that was valid at build time still checkable now.
		sigverify.WithTransparencyLog(1),
		sigverify.WithObserverTimestamps(1),
	)
	if err != nil {
		return Result{}, fmt.Errorf("building the signature verifier: %w", err)
	}

	digestBytes, err := hex.DecodeString(strings.TrimPrefix(digest.DigestStr(), "sha256:"))
	if err != nil {
		return Result{}, fmt.Errorf("decoding digest %s: %w", digest.DigestStr(), err)
	}

	policy := sigverify.NewPolicy(
		// The attestation must be over THIS digest. Without it a valid
		// attestation for some other image would satisfy the signature check.
		sigverify.WithArtifactDigest("sha256", digestBytes),
		sigverify.WithCertificateIdentity(certID),
	)

	var failures []string
	for _, raw := range bundles {
		observed, err := v.verifyOne(raw, verifier, policy, want)
		if err != nil {
			failures = append(failures, err.Error())
			continue
		}
		return Result{Digest: digest.DigestStr(), Observed: observed}, nil
	}

	return Result{}, fmt.Errorf(
		"no provenance attestation on %s satisfies this workload's build identity: %s",
		digest.DigestStr(), strings.Join(failures, "; "))
}

// verifyOne verifies a single bundle and matches its predicate.
func (v *Verifier) verifyOne(
	raw []byte,
	verifier *sigverify.Verifier,
	policy sigverify.PolicyBuilder,
	want Identity,
) (Observed, error) {
	var b bundle.Bundle
	if err := b.UnmarshalJSON(raw); err != nil {
		return Observed{}, fmt.Errorf("parsing the attestation bundle: %w", err)
	}

	result, err := verifier.Verify(&b, policy)
	if err != nil {
		return Observed{}, fmt.Errorf("signature verification failed: %w", err)
	}
	if result.Statement == nil {
		return Observed{}, errors.New("the bundle verified but carries no in-toto statement")
	}

	// Checked again after verification, not taken from the registry annotation
	// that was used to filter.
	if result.Statement.PredicateType != SLSAProvenancePredicateType {
		return Observed{}, fmt.Errorf(
			"verified statement is a %q, not a SLSA provenance", result.Statement.PredicateType)
	}

	observed, err := parsePredicate(result.Statement.Predicate)
	if err != nil {
		return Observed{}, err
	}
	if err := want.Match(observed); err != nil {
		return Observed{}, err
	}
	return observed, nil
}

// slsaPredicate is the part of a SLSA v1 provenance this project reads.
//
// Only these fields are decoded. The document carries a great deal more, and
// silently ignoring the rest is deliberate: a field nobody checks is a field
// that cannot be relied on, and decoding it would suggest otherwise.
type slsaPredicate struct {
	BuildDefinition struct {
		ExternalParameters struct {
			Workflow struct {
				Repository string `json:"repository"`
				Path       string `json:"path"`
				Ref        string `json:"ref"`
			} `json:"workflow"`
		} `json:"externalParameters"`
	} `json:"buildDefinition"`
	RunDetails struct {
		Builder struct {
			ID string `json:"id"`
		} `json:"builder"`
	} `json:"runDetails"`
}

// parsePredicate pulls the source fields out of a verified SLSA statement.
func parsePredicate(predicate any) (Observed, error) {
	// The statement arrives as a decoded structpb, so it is re-encoded rather
	// than reached into with type assertions. One round trip through JSON is
	// cheaper than being wrong about the shape.
	raw, err := json.Marshal(predicate)
	if err != nil {
		return Observed{}, fmt.Errorf("re-encoding the provenance predicate: %w", err)
	}

	var p slsaPredicate
	if err := json.Unmarshal(raw, &p); err != nil {
		return Observed{}, fmt.Errorf("decoding the provenance predicate: %w", err)
	}

	workflow := p.BuildDefinition.ExternalParameters.Workflow
	if workflow.Repository == "" {
		return Observed{}, errors.New(
			"the provenance names no source repository, so there is nothing to match against")
	}

	return Observed{
		SourceRepository: workflow.Repository,
		WorkflowPath:     workflow.Path,
		WorkflowRef:      workflow.Ref,
		BuilderID:        p.RunDetails.Builder.ID,
	}, nil
}
