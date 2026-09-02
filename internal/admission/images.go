// Package admission holds the ValidatingAdmissionWebhook that refuses a
// workload whose images were not built by the identity it is allowed to run.
package admission

import (
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
)

// imagesOf returns every image reference an object will run.
//
// Two shapes are understood. A Pod, where the images are in the container
// lists, and any custom resource with a string at spec.image, which is what the
// WebApp resource this project guards looks like. Anything else returns no
// images, and the caller decides what that means: silently admitting a workload
// whose images could not be found would be the worst possible default, so the
// caller refuses instead.
func imagesOf(object runtime.Object) ([]string, error) {
	if pod, ok := object.(*corev1.Pod); ok {
		return podImages(pod), nil
	}

	u, ok := object.(*unstructured.Unstructured)
	if !ok {
		return nil, fmt.Errorf("cannot read images out of a %T", object)
	}

	// Containers first, so a custom resource that embeds a pod template is
	// handled the same way a Pod is.
	if images := unstructuredPodImages(u); len(images) > 0 {
		return images, nil
	}

	image, found, err := unstructured.NestedString(u.Object, "spec", "image")
	if err != nil {
		return nil, fmt.Errorf("reading spec.image of %s/%s: %w", u.GetNamespace(), u.GetName(), err)
	}
	if found && image != "" {
		return []string{image}, nil
	}

	return nil, fmt.Errorf(
		"found no images in %s %s/%s: neither a container list nor spec.image",
		u.GetKind(), u.GetNamespace(), u.GetName())
}

// podImages collects images from all three container lists.
//
// Init containers and ephemeral containers are included on purpose. An init
// container runs with the same access to the pod's volumes and network as the
// application does, and an ephemeral container is a way to attach arbitrary code
// to a running pod. Checking only spec.containers would leave two doors open.
func podImages(pod *corev1.Pod) []string {
	images := make([]string, 0,
		len(pod.Spec.Containers)+len(pod.Spec.InitContainers)+len(pod.Spec.EphemeralContainers))
	for _, c := range pod.Spec.InitContainers {
		images = append(images, c.Image)
	}
	for _, c := range pod.Spec.Containers {
		images = append(images, c.Image)
	}
	for _, c := range pod.Spec.EphemeralContainers {
		images = append(images, c.Image)
	}
	return images
}

// unstructuredPodImages reads container lists out of an unstructured object.
func unstructuredPodImages(u *unstructured.Unstructured) []string {
	var images []string
	for _, field := range []string{"initContainers", "containers", "ephemeralContainers"} {
		list, found, err := unstructured.NestedSlice(u.Object, "spec", field)
		if err != nil || !found {
			continue
		}
		for _, item := range list {
			container, ok := item.(map[string]any)
			if !ok {
				continue
			}
			if image, ok := container["image"].(string); ok && image != "" {
				images = append(images, image)
			}
		}
	}
	return images
}
