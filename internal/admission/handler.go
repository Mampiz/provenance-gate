package admission

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"

	provenancev1alpha1 "github.com/Mampiz/provenance-gate/api/v1alpha1"
	"github.com/Mampiz/provenance-gate/internal/provenance"
)

// Verifier is the part of provenance.Verifier this handler needs. It is an
// interface so the admission logic can be tested without a registry, a
// transparency log or a network.
type Verifier interface {
	Verify(ctx context.Context, imageRef string, want provenance.Identity) (provenance.Result, error)
}

// Handler decides whether a workload may run the images it declares.
type Handler struct {
	Client   client.Reader
	Verifier Verifier
	Cache    *provenance.Cache

	// Timeout bounds the whole decision. The webhook configuration also carries
	// a timeoutSeconds, but relying on the API server to give up is not the same
	// as giving up: without this, a slow registry keeps a goroutine and a
	// connection alive long after the answer stopped mattering.
	Timeout time.Duration
}

// Handle implements admission.Handler.
func (h *Handler) Handle(ctx context.Context, req admission.Request) admission.Response {
	log := logf.FromContext(ctx).WithValues(
		"kind", req.Kind.Kind,
		"namespace", req.Namespace,
		"name", req.Name,
	)

	if h.Timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, h.Timeout)
		defer cancel()
	}

	object, err := decode(req)
	if err != nil {
		return admission.Errored(http.StatusBadRequest, err)
	}

	images, err := imagesOf(object)
	if err != nil {
		// Not being able to find the images is a refusal, not a pass. A workload
		// whose images could not be read has not been shown to be trustworthy.
		return admission.Denied(err.Error())
	}
	if len(images) == 0 {
		return admission.Denied(fmt.Sprintf(
			"%s %s/%s declares no images, so there is nothing to verify",
			req.Kind.Kind, req.Namespace, req.Name))
	}

	identity, source, err := h.trustRootFor(ctx, req, object)
	if err != nil {
		return admission.Denied(err.Error())
	}

	want := provenance.Identity{
		Issuer:           identity.Issuer,
		Builder:          identity.Builder,
		SourceRepository: identity.SourceRepository,
		WorkflowPath:     identity.WorkflowPath,
		WorkflowRef:      identity.WorkflowRef,
	}

	for _, image := range images {
		if err := h.checkImageRepository(image, source); err != nil {
			return admission.Denied(err.Error())
		}

		result, cached, err := h.Cache.Do(ctx, image, want, h.Verifier.Verify)
		if err != nil {
			log.Info("refused", "image", image, "reason", err.Error())
			return admission.Denied(fmt.Sprintf(
				"image %q is refused by BuildIdentity %s/%s: %v",
				image, source.Namespace, source.Name, err))
		}
		log.V(1).Info("admitted image", "image", image, "digest", result.Digest, "cached", cached)
	}

	return admission.Allowed(fmt.Sprintf(
		"every image is built by the identity declared in BuildIdentity %s/%s",
		source.Namespace, source.Name))
}

// checkImageRepository refuses an image outside the repositories a trust root
// covers.
//
// Without this, a pod could carry its own governed image alongside an unrelated
// one and the unrelated one would never be looked at. The comparison is on the
// repository, so any tag or digest of an allowed repository is in scope.
func (h *Handler) checkImageRepository(image string, source *provenancev1alpha1.BuildIdentity) error {
	repository := repositoryOf(image)
	for _, allowed := range source.Spec.ImageRepositories {
		if repository == allowed {
			return nil
		}
	}
	return fmt.Errorf(
		"image %q is from repository %q, which BuildIdentity %s/%s does not cover (allowed: %s)",
		image, repository, source.Namespace, source.Name,
		strings.Join(source.Spec.ImageRepositories, ", "))
}

// repositoryOf strips a tag or digest from an image reference.
func repositoryOf(image string) string {
	if at := strings.Index(image, "@"); at != -1 {
		image = image[:at]
	}
	// Only look after the last slash so a registry port is not mistaken for a tag.
	if slash := strings.LastIndex(image, "/"); slash != -1 {
		if colon := strings.LastIndex(image[slash:], ":"); colon != -1 {
			return image[:slash+colon]
		}
		return image
	}
	if colon := strings.LastIndex(image, ":"); colon != -1 {
		return image[:colon]
	}
	return image
}

// trustRootFor finds the BuildIdentity governing this object.
//
// Exactly one must match. Zero is a refusal, because a workload with no trust
// root has not been vouched for by anything and admitting it would make the
// webhook a suggestion. More than one is also a refusal: picking one of several
// contradictory trust roots is a decision this code has no basis for making, and
// choosing the first would make the outcome depend on list ordering.
func (h *Handler) trustRootFor(
	ctx context.Context,
	req admission.Request,
	object runtime.Object,
) (provenancev1alpha1.BuildProvenance, *provenancev1alpha1.BuildIdentity, error) {
	var list provenancev1alpha1.BuildIdentityList
	if err := h.Client.List(ctx, &list, client.InNamespace(req.Namespace)); err != nil {
		if apierrors.IsNotFound(err) {
			return provenancev1alpha1.BuildProvenance{}, nil, fmt.Errorf(
				"the BuildIdentity API is not installed, so nothing can be verified")
		}
		return provenancev1alpha1.BuildProvenance{}, nil, fmt.Errorf(
			"listing BuildIdentity in namespace %s: %w", req.Namespace, err)
	}

	objectLabels := labels.Set(accessorLabels(object))

	var matched []*provenancev1alpha1.BuildIdentity
	for i := range list.Items {
		item := &list.Items[i]
		if matches(item, req, objectLabels) {
			matched = append(matched, item)
		}
	}

	switch len(matched) {
	case 1:
		return matched[0].Spec.Provenance, matched[0], nil
	case 0:
		return provenancev1alpha1.BuildProvenance{}, nil, fmt.Errorf(
			"no BuildIdentity in namespace %q governs %s %q, so there is no trust root to verify against",
			req.Namespace, req.Kind.Kind, req.Name)
	default:
		names := make([]string, 0, len(matched))
		for _, m := range matched {
			names = append(names, m.Name)
		}
		return provenancev1alpha1.BuildProvenance{}, nil, fmt.Errorf(
			"%d BuildIdentity resources govern %s %q (%s); exactly one must, because choosing between them would make admission depend on list ordering",
			len(matched), req.Kind.Kind, req.Name, strings.Join(names, ", "))
	}
}

// matches reports whether a BuildIdentity governs the object under admission.
func matches(identity *provenancev1alpha1.BuildIdentity, req admission.Request, objectLabels labels.Set) bool {
	subject := identity.Spec.Subject

	if subject.Kind != req.Kind.Kind {
		return false
	}
	if subject.APIVersion != apiVersionOf(req) {
		return false
	}

	if subject.Name != "" {
		// A generated name is empty in the admission request for a create, and
		// generateName carries the prefix instead. Matching by name cannot work
		// for those, which is why Selector exists.
		return subject.Name == req.Name
	}

	if subject.Selector != nil {
		selector, err := metav1.LabelSelectorAsSelector(subject.Selector)
		if err != nil {
			// A selector that does not parse governs nothing. It cannot be made
			// to match everything, which would turn a broken trust root into a
			// permissive one.
			return false
		}
		return selector.Matches(objectLabels)
	}

	return false
}

// apiVersionOf renders the request's group/version the way a manifest writes it.
func apiVersionOf(req admission.Request) string {
	if req.Kind.Group == "" {
		return req.Kind.Version
	}
	return req.Kind.Group + "/" + req.Kind.Version
}

// accessorLabels returns an object's labels, or nil when it has none.
func accessorLabels(object runtime.Object) map[string]string {
	accessor, ok := object.(metav1.Object)
	if !ok {
		return nil
	}
	return accessor.GetLabels()
}
