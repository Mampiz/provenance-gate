package admission

import (
	"encoding/json"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

// decode turns the raw object in an admission request into something images can
// be read from.
//
// Pods are decoded into their typed form because the container lists are worth
// having the compiler check. Everything else stays unstructured: the whole point
// is to guard custom resources this binary does not import, so it cannot have
// their Go types.
func decode(req admission.Request) (runtime.Object, error) {
	if len(req.Object.Raw) == 0 {
		return nil, fmt.Errorf(
			"the admission request for %s %s/%s carries no object",
			req.Kind.Kind, req.Namespace, req.Name)
	}

	if req.Kind.Group == "" && req.Kind.Kind == "Pod" {
		var pod corev1.Pod
		if err := json.Unmarshal(req.Object.Raw, &pod); err != nil {
			return nil, fmt.Errorf("decoding Pod %s/%s: %w", req.Namespace, req.Name, err)
		}
		return &pod, nil
	}

	u := &unstructured.Unstructured{}
	if err := u.UnmarshalJSON(req.Object.Raw); err != nil {
		return nil, fmt.Errorf(
			"decoding %s %s/%s: %w", req.Kind.Kind, req.Namespace, req.Name, err)
	}
	return u, nil
}
