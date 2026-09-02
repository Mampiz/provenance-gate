// Package controller keeps the trust registry honest.
//
// The webhook reads BuildIdentity resources on the admission path, where there
// is no room to work out whether one makes sense. This controller does that
// ahead of time and records the answer in the status, so a trust root that
// could never admit anything says so in kubectl get rather than by silently
// refusing every deploy.
package controller

import (
	"context"
	"fmt"
	"strings"

	"github.com/google/go-containerregistry/pkg/name"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	provenancev1alpha1 "github.com/Mampiz/provenance-gate/api/v1alpha1"
	"github.com/Mampiz/provenance-gate/internal/provenance"
)

// BuildIdentityReconciler reports whether a trust root is usable.
type BuildIdentityReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=provenance.miportfolio.com,resources=buildidentities,verbs=get;list;watch
// +kubebuilder:rbac:groups=provenance.miportfolio.com,resources=buildidentities/status,verbs=get;update;patch

// Reconcile validates one BuildIdentity and records the verdict.
func (r *BuildIdentityReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	var identity provenancev1alpha1.BuildIdentity
	if err := r.Get(ctx, req.NamespacedName, &identity); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	condition := metav1.Condition{
		Type:               provenancev1alpha1.ConditionReady,
		Status:             metav1.ConditionTrue,
		Reason:             "TrustRootUsable",
		Message:            "the trust root is complete and will be enforced",
		ObservedGeneration: identity.Generation,
	}

	if err := validate(&identity); err != nil {
		condition.Status = metav1.ConditionFalse
		condition.Reason = "TrustRootUnusable"
		condition.Message = err.Error()
	}

	meta := &identity.Status
	meta.ObservedGeneration = identity.Generation
	setCondition(&meta.Conditions, condition)

	if err := r.Status().Update(ctx, &identity); err != nil {
		// A conflict means somebody else wrote first, and the next reconcile
		// will compute the same answer against the newer object.
		if apierrors.IsConflict(err) {
			return ctrl.Result{Requeue: true}, nil
		}
		return ctrl.Result{}, fmt.Errorf("updating the status of %s: %w", req.NamespacedName, err)
	}
	return ctrl.Result{}, nil
}

// validate reports why a trust root could never do its job.
//
// Everything here is checkable without touching the network. Reaching out to a
// registry from a reconcile would make the readiness of a trust root depend on
// whether an image happens to have been pushed yet, which is a different
// question from whether the trust root is well formed.
func validate(identity *provenancev1alpha1.BuildIdentity) error {
	want := provenance.Identity{
		Issuer:           identity.Spec.Provenance.Issuer,
		Builder:          identity.Spec.Provenance.Builder,
		SourceRepository: identity.Spec.Provenance.SourceRepository,
	}
	if err := want.Validate(); err != nil {
		return err
	}

	subject := identity.Spec.Subject
	if (subject.Name == "") == (subject.Selector == nil) {
		return fmt.Errorf("exactly one of subject.name or subject.selector must be set")
	}
	if subject.Selector != nil {
		if _, err := metav1.LabelSelectorAsSelector(subject.Selector); err != nil {
			return fmt.Errorf("subject.selector does not parse: %w", err)
		}
	}

	var problems []string
	for _, repository := range identity.Spec.ImageRepositories {
		// Parsed rather than pattern-matched, so a reference the registry client
		// will later reject is caught here instead of at admission time. The
		// parser handles a registry port correctly and rejects a tag.
		if _, err := name.NewRepository(repository); err != nil {
			if hasTag(repository) {
				// By far the most common mistake is pasting a full image
				// reference, and the parser's complaint about allowed
				// characters does not point at it.
				problems = append(problems, fmt.Sprintf(
					"%q carries a tag; list the repository instead, and every tag and digest of it is covered", repository))
				continue
			}
			problems = append(problems, fmt.Sprintf("%q is not a valid image repository: %v", repository, err))
		}
	}
	if len(problems) > 0 {
		return fmt.Errorf("%s", strings.Join(problems, "; "))
	}
	return nil
}

// hasTag reports whether a reference carries a tag, looking only after the last
// slash so a registry port is not mistaken for one.
func hasTag(reference string) bool {
	return strings.Contains(reference[strings.LastIndex(reference, "/")+1:], ":")
}

// setCondition replaces a condition of the same type, keeping its transition
// time when the status has not changed.
func setCondition(conditions *[]metav1.Condition, condition metav1.Condition) {
	condition.LastTransitionTime = metav1.Now()
	for i, existing := range *conditions {
		if existing.Type != condition.Type {
			continue
		}
		if existing.Status == condition.Status {
			condition.LastTransitionTime = existing.LastTransitionTime
		}
		(*conditions)[i] = condition
		return
	}
	*conditions = append(*conditions, condition)
}

// SetupWithManager registers the reconciler.
func (r *BuildIdentityReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&provenancev1alpha1.BuildIdentity{}).
		Named("buildidentity").
		Complete(r)
}
