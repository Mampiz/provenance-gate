// Package provenance resolves a container image to a digest, fetches the SLSA
// provenance attestation attached to that digest, verifies it, and checks that
// what it says matches the build identity a workload is allowed to run.
//
// The order matters and is not negotiable. A tag is resolved to a digest first,
// and everything after that point is about the digest. Verifying attestations
// attached to a tag would verify whatever the tag pointed at when the check ran,
// which is not necessarily what the kubelet will pull.
package provenance

import (
	"fmt"
	"strings"
)

// Identity is what an image's provenance has to prove. It comes from a
// BuildIdentity resource, never from the workload being admitted.
type Identity struct {
	// Issuer is the OIDC issuer of the signing certificate.
	Issuer string
	// Builder is the certificate SAN: the workflow that performed the build.
	Builder string
	// SourceRepository is the repository the provenance must name as the source.
	SourceRepository string
	// WorkflowPath, when set, is the calling workflow's path within the source
	// repository. Empty means any workflow of that repository is accepted.
	WorkflowPath string
	// WorkflowRef, when set, is the git ref the build ran from. Empty means any
	// ref is accepted.
	WorkflowRef string
}

// Validate rejects an Identity that could never refuse anything.
//
// An empty Issuer or Builder would make the signature check accept any
// certificate, and an empty SourceRepository would make the whole comparison a
// no-op. A trust root that trusts everything is worse than no trust root,
// because it looks like a control in every report.
func (i Identity) Validate() error {
	var missing []string
	if i.Issuer == "" {
		missing = append(missing, "issuer")
	}
	if i.Builder == "" {
		missing = append(missing, "builder")
	}
	if i.SourceRepository == "" {
		missing = append(missing, "sourceRepository")
	}
	if len(missing) > 0 {
		return fmt.Errorf("incomplete build identity: %s must be set", strings.Join(missing, ", "))
	}
	return nil
}

// Observed is what a verified provenance document actually said. It exists so a
// rejection can report the difference rather than just saying no.
type Observed struct {
	SourceRepository string
	WorkflowPath     string
	WorkflowRef      string
	BuilderID        string
}

// Match reports whether an observed provenance satisfies the identity.
//
// Every comparison is exact. Prefix or suffix matching on a repository URL is
// how "github.com/Mampiz/my-service" comes to accept
// "github.com/attacker/my-service-evil".
func (i Identity) Match(o Observed) error {
	if o.SourceRepository != i.SourceRepository {
		return fmt.Errorf(
			"image was built from %q, but this workload may only run images built from %q",
			o.SourceRepository, i.SourceRepository)
	}
	if i.WorkflowPath != "" && o.WorkflowPath != i.WorkflowPath {
		return fmt.Errorf(
			"image was built by workflow %q, but this workload requires %q",
			o.WorkflowPath, i.WorkflowPath)
	}
	if i.WorkflowRef != "" && o.WorkflowRef != i.WorkflowRef {
		return fmt.Errorf(
			"image was built from ref %q, but this workload requires %q",
			o.WorkflowRef, i.WorkflowRef)
	}
	return nil
}
