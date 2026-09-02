package provenance

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/remote"
)

const (
	// SLSAProvenancePredicateType is the predicate the build workflow attaches.
	SLSAProvenancePredicateType = "https://slsa.dev/provenance/v1"

	// sigstoreBundleArtifactType is the OCI artifactType of an attestation
	// pushed to a registry by actions/attest-build-provenance.
	sigstoreBundleArtifactType = "application/vnd.dev.sigstore.bundle.v0.3+json"

	// predicateTypeAnnotation lets a referrer be filtered without fetching its
	// blob. An image can carry a provenance attestation, an SBOM and a signature,
	// and pulling all three to find one is three round trips on the admission
	// path instead of one.
	predicateTypeAnnotation = "dev.sigstore.bundle.predicateType"

	// maxBundleBytes caps what will be read out of a registry blob. The registry
	// is not trusted to be honest about size, and an admission handler that can
	// be made to allocate without bound is a denial of service against every
	// workload the webhook guards.
	maxBundleBytes = 8 << 20
)

// ErrNoAttestation means the image has no provenance attestation attached. It
// is a distinct error because it is the ordinary case for an unsigned image and
// deserves a message that says so rather than a parse failure.
var ErrNoAttestation = errors.New("no SLSA provenance attestation is attached to this image")

// Registry reads images and their attestations from an OCI registry.
type Registry struct {
	keychain authn.Keychain
	puller   *remote.Puller
}

// NewRegistry returns a Registry using ambient credentials.
//
// The Puller is created once and shared. Without it every call negotiates a
// fresh bearer token with the registry and opens a fresh TLS connection, and
// one verification makes three calls: resolve the digest, list the referrers,
// pull the blob. On the admission path that is three token exchanges and three
// handshakes for one answer, which is most of the cost.
func NewRegistry() (*Registry, error) {
	keychain := authn.DefaultKeychain
	puller, err := remote.NewPuller(
		remote.WithAuthFromKeychain(keychain),
		remote.WithTransport(transport()),
	)
	if err != nil {
		return nil, fmt.Errorf("building the registry client: %w", err)
	}
	return &Registry{keychain: keychain, puller: puller}, nil
}

// transport keeps connections alive between verifications. The default
// http.Transport is fine, but its idle timeout is short enough that a webhook
// verifying one image every few minutes reconnects every time.
func transport() http.RoundTripper {
	base := http.DefaultTransport.(*http.Transport).Clone()
	base.MaxIdleConnsPerHost = 8
	base.IdleConnTimeout = 5 * time.Minute
	return base
}

// Resolve turns any image reference into a digest reference.
//
// This is the first thing that happens to every image and the reason the rest
// of the checks mean anything. A tag is a mutable pointer: verifying what it
// points at now says nothing about what it will point at when the image is
// pulled. A reference that is already a digest is returned unchanged, with no
// network call.
func (r *Registry) Resolve(ctx context.Context, imageRef string) (name.Digest, error) {
	ref, err := name.ParseReference(imageRef)
	if err != nil {
		return name.Digest{}, fmt.Errorf("parsing image reference %q: %w", imageRef, err)
	}

	if digest, ok := ref.(name.Digest); ok {
		return digest, nil
	}

	descriptor, err := r.puller.Head(ctx, ref)
	if err != nil {
		return name.Digest{}, fmt.Errorf("resolving %q to a digest: %w", imageRef, err)
	}

	digest, err := name.NewDigest(ref.Context().Name() + "@" + descriptor.Digest.String())
	if err != nil {
		return name.Digest{}, fmt.Errorf("building digest reference for %q: %w", imageRef, err)
	}
	return digest, nil
}

// FetchAttestations returns the raw Sigstore bundles attached to a digest that
// carry the given predicate type.
//
// More than one can come back. An image rebuilt from the same source produces a
// second attestation over the same digest, and both are legitimate, so the
// caller verifies them in turn and accepts the first that satisfies the policy.
func (r *Registry) FetchAttestations(ctx context.Context, digest name.Digest, predicateType string) ([][]byte, error) {
	index, err := remote.Referrers(digest,
		remote.WithContext(ctx),
		remote.Reuse(r.puller),
	)
	if err != nil {
		return nil, fmt.Errorf("listing referrers of %s: %w", digest, err)
	}

	manifest, err := index.IndexManifest()
	if err != nil {
		return nil, fmt.Errorf("reading the referrers index of %s: %w", digest, err)
	}

	var bundles [][]byte
	for _, descriptor := range manifest.Manifests {
		if descriptor.ArtifactType != sigstoreBundleArtifactType {
			continue
		}
		// The annotation is a hint from the registry and is not trusted: the
		// predicate type inside the verified statement is checked again after
		// verification. It is used here only to avoid fetching blobs that
		// certainly are not the one being looked for.
		if got := descriptor.Annotations[predicateTypeAnnotation]; got != "" && got != predicateType {
			continue
		}

		raw, err := r.fetchBundleBlob(ctx, digest.Context(), descriptor)
		if err != nil {
			return nil, err
		}
		bundles = append(bundles, raw)
	}

	if len(bundles) == 0 {
		return nil, ErrNoAttestation
	}
	return bundles, nil
}

// fetchBundleBlob pulls the single layer of an attestation manifest.
func (r *Registry) fetchBundleBlob(ctx context.Context, repo name.Repository, descriptor v1.Descriptor) ([]byte, error) {
	ref := repo.Digest(descriptor.Digest.String())

	descriptorImage, err := r.puller.Get(ctx, ref)
	if err != nil {
		return nil, fmt.Errorf("fetching attestation manifest %s: %w", descriptor.Digest, err)
	}
	image, err := descriptorImage.Image()
	if err != nil {
		return nil, fmt.Errorf("fetching attestation manifest %s: %w", descriptor.Digest, err)
	}

	layers, err := image.Layers()
	if err != nil {
		return nil, fmt.Errorf("reading layers of attestation %s: %w", descriptor.Digest, err)
	}
	if len(layers) != 1 {
		return nil, fmt.Errorf("attestation %s has %d layers, expected exactly 1", descriptor.Digest, len(layers))
	}

	reader, err := layers[0].Uncompressed()
	if err != nil {
		return nil, fmt.Errorf("opening attestation blob %s: %w", descriptor.Digest, err)
	}
	defer func() { _ = reader.Close() }()

	raw, err := io.ReadAll(io.LimitReader(reader, maxBundleBytes+1))
	if err != nil {
		return nil, fmt.Errorf("reading attestation blob %s: %w", descriptor.Digest, err)
	}
	if len(raw) > maxBundleBytes {
		return nil, fmt.Errorf("attestation blob %s is larger than the %d byte limit", descriptor.Digest, maxBundleBytes)
	}
	if !json.Valid(raw) {
		return nil, fmt.Errorf("attestation blob %s is not valid JSON", descriptor.Digest)
	}
	return raw, nil
}
