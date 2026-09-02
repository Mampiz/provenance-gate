// Package v1alpha1 contains the BuildIdentity API.
//
// A BuildIdentity is the trust root for one workload: it says which build, on
// which builder, from which source, is allowed to produce the images that
// workload runs. It is deliberately a separate object from the workload rather
// than an annotation on it, because an expected value supplied by the thing
// being checked is not a check. See docs/decisions/0007.
//
// +kubebuilder:object:generate=true
// +groupName=provenance.miportfolio.com
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	// GroupVersion is group version used to register these objects.
	GroupVersion = schema.GroupVersion{Group: "provenance.miportfolio.com", Version: "v1alpha1"}

	// SchemeBuilder is used to add go types to the GroupVersionKind scheme.
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	// AddToScheme adds the types in this group-version to the given scheme.
	AddToScheme = SchemeBuilder.AddToScheme
)
