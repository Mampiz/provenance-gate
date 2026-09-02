package admission

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"

	provenancev1alpha1 "github.com/Mampiz/provenance-gate/api/v1alpha1"
	"github.com/Mampiz/provenance-gate/internal/provenance"
)

const (
	issuer  = "https://token.actions.githubusercontent.com"
	builder = "https://github.com/Mampiz/provenance-gate/.github/workflows/build-sign.yml@refs/heads/main"
	ourRepo = "https://github.com/Mampiz/my-service"
	theirs  = "https://github.com/Mampiz/some-other-service"
)

// fakeVerifier answers with whatever the provenance of an image is said to be,
// so the handler can be tested without a registry or a transparency log. The
// signature checking itself is the verifier package's problem, not this one's.
type fakeVerifier struct {
	// builtFrom maps an image reference to the repository its provenance names.
	builtFrom map[string]string
	calls     int
}

func (f *fakeVerifier) Verify(_ context.Context, imageRef string, want provenance.Identity) (provenance.Result, error) {
	f.calls++
	repo, ok := f.builtFrom[imageRef]
	if !ok {
		return provenance.Result{}, provenance.ErrNoAttestation
	}
	observed := provenance.Observed{SourceRepository: repo, BuilderID: builder}
	if err := want.Match(observed); err != nil {
		return provenance.Result{}, err
	}
	return provenance.Result{Digest: "sha256:deadbeef", Observed: observed}, nil
}

func scheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := provenancev1alpha1.AddToScheme(s); err != nil {
		t.Fatalf("registering the BuildIdentity scheme: %v", err)
	}
	return s
}

func buildIdentity(name string, subjects ...provenancev1alpha1.SubjectReference) *provenancev1alpha1.BuildIdentity {
	return &provenancev1alpha1.BuildIdentity{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "apps"},
		Spec: provenancev1alpha1.BuildIdentitySpec{
			Subjects:          subjects,
			ImageRepositories: []string{"ghcr.io/mampiz/my-service"},
			Provenance: provenancev1alpha1.BuildProvenance{
				Issuer:           issuer,
				Builder:          builder,
				SourceRepository: ourRepo,
			},
		},
	}
}

func podSubject(name string) provenancev1alpha1.SubjectReference {
	return provenancev1alpha1.SubjectReference{APIVersion: "v1", Kind: "Pod", Name: name}
}

func podRequest(t *testing.T, name string, images ...string) admission.Request {
	t.Helper()
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: "apps",
			Labels:    map[string]string{"app": "my-service"},
		},
	}
	for i, image := range images {
		pod.Spec.Containers = append(pod.Spec.Containers, corev1.Container{
			Name:  "c" + string(rune('0'+i)),
			Image: image,
		})
	}
	raw, err := json.Marshal(pod)
	if err != nil {
		t.Fatalf("marshalling the pod: %v", err)
	}
	return admission.Request{AdmissionRequest: admissionv1.AdmissionRequest{
		Kind:      metav1.GroupVersionKind{Version: "v1", Kind: "Pod"},
		Namespace: "apps",
		Name:      name,
		Operation: admissionv1.Create,
		Object:    runtime.RawExtension{Raw: raw},
	}}
}

func handlerWith(t *testing.T, verifier Verifier, objects ...runtime.Object) *Handler {
	t.Helper()
	return &Handler{
		Client: fake.NewClientBuilder().
			WithScheme(scheme(t)).
			WithRuntimeObjects(objects...).
			Build(),
		Verifier: verifier,
		Cache:    provenance.NewCache(time.Minute, 10*time.Second, 100),
		Timeout:  5 * time.Second,
	}
}

// The three cases the project exists to demonstrate.
func TestTheThreeCases(t *testing.T) {
	const (
		ours    = "ghcr.io/mampiz/my-service:v1"
		foreign = "ghcr.io/mampiz/my-service:built-elsewhere"
		naked   = "ghcr.io/mampiz/my-service:unsigned"
	)

	verifier := &fakeVerifier{builtFrom: map[string]string{
		ours: ourRepo,
		// A real image, correctly signed, built by a workflow that is entirely
		// legitimate and belongs to a different service.
		foreign: theirs,
		// naked is absent: no attestation at all.
	}}

	h := handlerWith(t, verifier, buildIdentity("my-service", podSubject("my-service")))

	t.Run("built by the right workflow is admitted", func(t *testing.T) {
		resp := h.Handle(context.Background(), podRequest(t, "my-service", ours))
		if !resp.Allowed {
			t.Fatalf("the correctly built image was refused: %s", resp.Result.Message)
		}
	})

	t.Run("unsigned is rejected", func(t *testing.T) {
		resp := h.Handle(context.Background(), podRequest(t, "my-service", naked))
		if resp.Allowed {
			t.Fatal("an image with no attestation was admitted")
		}
		if !strings.Contains(resp.Result.Message, "no SLSA provenance") {
			t.Errorf("the message does not say the attestation is missing: %s", resp.Result.Message)
		}
	})

	// This is the one that carries the argument. The signature is valid, the
	// builder is trusted, the issuer is right, and it still has to be refused
	// because the build does not belong to this workload.
	t.Run("signed by another legitimate workflow is rejected", func(t *testing.T) {
		resp := h.Handle(context.Background(), podRequest(t, "my-service", foreign))
		if resp.Allowed {
			t.Fatal("an image built by a different service's workflow was admitted")
		}
		if !strings.Contains(resp.Result.Message, "some-other-service") {
			t.Errorf("the message does not name the repository it was actually built from: %s", resp.Result.Message)
		}
	})
}

func TestWorkloadWithNoTrustRootIsRefused(t *testing.T) {
	// Fail closed. A workload nothing vouches for must not slip through just
	// because nobody wrote a BuildIdentity for it, or the webhook is a
	// suggestion rather than a control.
	verifier := &fakeVerifier{builtFrom: map[string]string{"ghcr.io/mampiz/my-service:v1": ourRepo}}
	h := handlerWith(t, verifier)

	resp := h.Handle(context.Background(), podRequest(t, "orphan", "ghcr.io/mampiz/my-service:v1"))
	if resp.Allowed {
		t.Fatal("a workload with no BuildIdentity was admitted")
	}
	if !strings.Contains(resp.Result.Message, "no BuildIdentity") {
		t.Errorf("unhelpful message: %s", resp.Result.Message)
	}
	if verifier.calls != 0 {
		t.Error("the registry was contacted for a workload that had no trust root to check against")
	}
}

func TestAmbiguousTrustRootsAreRefused(t *testing.T) {
	// Two trust roots that both claim the workload. Choosing one would make the
	// outcome depend on the order the API server returned them in.
	verifier := &fakeVerifier{builtFrom: map[string]string{"ghcr.io/mampiz/my-service:v1": ourRepo}}
	strict := buildIdentity("strict", podSubject("my-service"))
	loose := buildIdentity("loose", podSubject("my-service"))
	loose.Spec.Provenance.SourceRepository = theirs

	h := handlerWith(t, verifier, strict, loose)
	resp := h.Handle(context.Background(), podRequest(t, "my-service", "ghcr.io/mampiz/my-service:v1"))

	if resp.Allowed {
		t.Fatal("an ambiguously governed workload was admitted")
	}
	if !strings.Contains(resp.Result.Message, "exactly one") {
		t.Errorf("the message does not explain the ambiguity: %s", resp.Result.Message)
	}
}

func TestSelectorMatchesGeneratedPodNames(t *testing.T) {
	// Pods created by a ReplicaSet have generated names, so a trust root that
	// could only match by name would never govern a real Deployment's pods.
	verifier := &fakeVerifier{builtFrom: map[string]string{"ghcr.io/mampiz/my-service:v1": ourRepo}}
	identity := buildIdentity("by-label", provenancev1alpha1.SubjectReference{
		APIVersion: "v1",
		Kind:       "Pod",
		Selector:   &metav1.LabelSelector{MatchLabels: map[string]string{"app": "my-service"}},
	})

	h := handlerWith(t, verifier, identity)
	resp := h.Handle(context.Background(), podRequest(t, "my-service-7d9f8b6c4-x2kqp", "ghcr.io/mampiz/my-service:v1"))

	if !resp.Allowed {
		t.Fatalf("a pod with a generated name was refused: %s", resp.Result.Message)
	}
}

func TestEveryContainerIsChecked(t *testing.T) {
	// An init container runs with the same access to the pod as the application
	// does. Checking only spec.containers would leave it unguarded.
	const good = "ghcr.io/mampiz/my-service:v1"
	const bad = "ghcr.io/mampiz/my-service:built-elsewhere"
	verifier := &fakeVerifier{builtFrom: map[string]string{good: ourRepo, bad: theirs}}
	h := handlerWith(t, verifier, buildIdentity("my-service", podSubject("my-service")))

	req := podRequest(t, "my-service", good)
	var pod corev1.Pod
	if err := json.Unmarshal(req.Object.Raw, &pod); err != nil {
		t.Fatal(err)
	}
	pod.Spec.InitContainers = []corev1.Container{{Name: "setup", Image: bad}}
	raw, err := json.Marshal(&pod)
	if err != nil {
		t.Fatal(err)
	}
	req.Object.Raw = raw

	resp := h.Handle(context.Background(), req)
	if resp.Allowed {
		t.Fatal("an init container built by another service's workflow was admitted")
	}
}

func TestImageOutsideTheCoveredRepositoriesIsRefused(t *testing.T) {
	// A pod could otherwise carry its own governed image alongside an unrelated
	// one, and the unrelated one would never be looked at.
	verifier := &fakeVerifier{builtFrom: map[string]string{
		"ghcr.io/mampiz/my-service:v1": ourRepo,
		"docker.io/library/nginx:1.27": ourRepo,
	}}
	h := handlerWith(t, verifier, buildIdentity("my-service", podSubject("my-service")))

	resp := h.Handle(context.Background(), podRequest(t, "my-service",
		"ghcr.io/mampiz/my-service:v1", "docker.io/library/nginx:1.27"))

	if resp.Allowed {
		t.Fatal("an image from an uncovered repository was admitted")
	}
	if !strings.Contains(resp.Result.Message, "does not cover") {
		t.Errorf("unhelpful message: %s", resp.Result.Message)
	}
}

func TestCustomResourceWithSpecImage(t *testing.T) {
	// The WebApp resource this project guards puts its image at spec.image
	// rather than in a container list.
	verifier := &fakeVerifier{builtFrom: map[string]string{"ghcr.io/mampiz/my-service:v1": ourRepo}}
	identity := buildIdentity("webapp", provenancev1alpha1.SubjectReference{
		APIVersion: "platform.miportfolio.com/v1",
		Kind:       "WebApp",
		Name:       "my-service",
	})
	h := handlerWith(t, verifier, identity)

	raw, err := json.Marshal(map[string]any{
		"apiVersion": "platform.miportfolio.com/v1",
		"kind":       "WebApp",
		"metadata":   map[string]any{"name": "my-service", "namespace": "apps"},
		"spec":       map[string]any{"image": "ghcr.io/mampiz/my-service:v1", "port": 8080},
	})
	if err != nil {
		t.Fatal(err)
	}

	resp := h.Handle(context.Background(), admission.Request{AdmissionRequest: admissionv1.AdmissionRequest{
		Kind:      metav1.GroupVersionKind{Group: "platform.miportfolio.com", Version: "v1", Kind: "WebApp"},
		Namespace: "apps",
		Name:      "my-service",
		Operation: admissionv1.Create,
		Object:    runtime.RawExtension{Raw: raw},
	}})

	if !resp.Allowed {
		t.Fatalf("a correctly built WebApp was refused: %s", resp.Result.Message)
	}
}

func TestObjectWithNoImagesIsRefused(t *testing.T) {
	h := handlerWith(t, &fakeVerifier{}, buildIdentity("thing", provenancev1alpha1.SubjectReference{
		APIVersion: "example.com/v1", Kind: "Thing", Name: "t",
	}))

	raw, _ := json.Marshal(map[string]any{
		"apiVersion": "example.com/v1",
		"kind":       "Thing",
		"metadata":   map[string]any{"name": "t", "namespace": "apps"},
		"spec":       map[string]any{"replicas": 1},
	})
	resp := h.Handle(context.Background(), admission.Request{AdmissionRequest: admissionv1.AdmissionRequest{
		Kind:      metav1.GroupVersionKind{Group: "example.com", Version: "v1", Kind: "Thing"},
		Namespace: "apps",
		Name:      "t",
		Operation: admissionv1.Create,
		Object:    runtime.RawExtension{Raw: raw},
	}})

	if resp.Allowed {
		t.Fatal("an object whose images could not be found was admitted")
	}
}

func TestRepositoryOf(t *testing.T) {
	for image, want := range map[string]string{
		"ghcr.io/mampiz/my-service:v1":            "ghcr.io/mampiz/my-service",
		"ghcr.io/mampiz/my-service":               "ghcr.io/mampiz/my-service",
		"ghcr.io/mampiz/my-service@sha256:abc":    "ghcr.io/mampiz/my-service",
		"ghcr.io/mampiz/my-service:v1@sha256:abc": "ghcr.io/mampiz/my-service",
		"nginx:1.27": "nginx",
		"nginx":      "nginx",
		// A registry port must not be mistaken for a tag.
		"myregistry:5000/app":    "myregistry:5000/app",
		"myregistry:5000/app:v1": "myregistry:5000/app",
	} {
		if got := repositoryOf(image); got != want {
			t.Errorf("repositoryOf(%q) = %q, want %q", image, got, want)
		}
	}
}

func TestCachedRejectionsDoNotReVerify(t *testing.T) {
	verifier := &fakeVerifier{builtFrom: map[string]string{}}
	h := handlerWith(t, verifier, buildIdentity("my-service", podSubject("my-service")))

	for range 3 {
		resp := h.Handle(context.Background(), podRequest(t, "my-service", "ghcr.io/mampiz/my-service:v1"))
		if resp.Allowed {
			t.Fatal("an unsigned image was admitted")
		}
	}
	if verifier.calls != 1 {
		t.Errorf("verified %d times, expected the rejection to be cached", verifier.calls)
	}
}

func TestOneTrustRootGovernsBothTheCustomResourceAndItsPods(t *testing.T) {
	// A service takes more than one shape. The WebApp is admitted, then the
	// operator creates a Deployment whose pods are admitted separately, and both
	// have to prove the same build identity. Splitting that across two
	// BuildIdentity resources would be two places to keep in step.
	verifier := &fakeVerifier{builtFrom: map[string]string{"ghcr.io/mampiz/my-service:v1": ourRepo}}
	identity := buildIdentity("my-service",
		provenancev1alpha1.SubjectReference{
			APIVersion: "platform.miportfolio.com/v1",
			Kind:       "WebApp",
			Name:       "my-service",
		},
		provenancev1alpha1.SubjectReference{
			APIVersion: "v1",
			Kind:       "Pod",
			// The operator labels the pods it creates with app: <webapp name>.
			Selector: &metav1.LabelSelector{MatchLabels: map[string]string{"app": "my-service"}},
		},
	)
	h := handlerWith(t, verifier, identity)

	t.Run("the custom resource", func(t *testing.T) {
		raw, err := json.Marshal(map[string]any{
			"apiVersion": "platform.miportfolio.com/v1",
			"kind":       "WebApp",
			"metadata":   map[string]any{"name": "my-service", "namespace": "apps"},
			"spec":       map[string]any{"image": "ghcr.io/mampiz/my-service:v1", "port": 8080},
		})
		if err != nil {
			t.Fatal(err)
		}
		resp := h.Handle(context.Background(), admission.Request{AdmissionRequest: admissionv1.AdmissionRequest{
			Kind:      metav1.GroupVersionKind{Group: "platform.miportfolio.com", Version: "v1", Kind: "WebApp"},
			Namespace: "apps",
			Name:      "my-service",
			Operation: admissionv1.Create,
			Object:    runtime.RawExtension{Raw: raw},
		}})
		if !resp.Allowed {
			t.Fatalf("the WebApp was refused: %s", resp.Result.Message)
		}
	})

	t.Run("the pod the operator creates from it", func(t *testing.T) {
		req := podRequest(t, "my-service-deployment-7d9f8-x2kqp", "ghcr.io/mampiz/my-service:v1")
		var pod corev1.Pod
		if err := json.Unmarshal(req.Object.Raw, &pod); err != nil {
			t.Fatal(err)
		}
		pod.Labels = map[string]string{"app": "my-service"}
		raw, err := json.Marshal(&pod)
		if err != nil {
			t.Fatal(err)
		}
		req.Object.Raw = raw

		resp := h.Handle(context.Background(), req)
		if !resp.Allowed {
			t.Fatalf("the operator's pod was refused: %s", resp.Result.Message)
		}
	})

	t.Run("a pod of a different service is not governed by it", func(t *testing.T) {
		req := podRequest(t, "someone-else", "ghcr.io/mampiz/my-service:v1")
		var pod corev1.Pod
		if err := json.Unmarshal(req.Object.Raw, &pod); err != nil {
			t.Fatal(err)
		}
		pod.Labels = map[string]string{"app": "someone-else"}
		raw, err := json.Marshal(&pod)
		if err != nil {
			t.Fatal(err)
		}
		req.Object.Raw = raw

		resp := h.Handle(context.Background(), req)
		if resp.Allowed {
			t.Fatal("a pod belonging to no trust root was admitted")
		}
	})
}
