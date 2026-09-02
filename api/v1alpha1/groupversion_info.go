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
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// GroupVersion is the group version these objects are registered under.
var GroupVersion = schema.GroupVersion{Group: "provenance.miportfolio.com", Version: "v1alpha1"}

var (
	// SchemeBuilder collects the functions that add these types to a scheme.
	//
	// This is apimachinery's builder rather than controller-runtime's, which is
	// deprecated for a reason worth keeping: an API package should be cheap to
	// import, and pulling controller-runtime into it makes every consumer of
	// these types depend on a controller framework they may have no use for.
	SchemeBuilder = runtime.NewSchemeBuilder(addKnownTypes)

	// AddToScheme adds the types in this group-version to the given scheme.
	AddToScheme = SchemeBuilder.AddToScheme
)

func addKnownTypes(s *runtime.Scheme) error {
	s.AddKnownTypes(GroupVersion, &BuildIdentity{}, &BuildIdentityList{})
	metav1.AddToGroupVersion(s, GroupVersion)
	return nil
}
