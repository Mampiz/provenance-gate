package provenance

import (
	"strings"
	"testing"
)

func TestIdentityValidateRejectsIncompleteTrustRoots(t *testing.T) {
	complete := Identity{
		Issuer:           "https://token.actions.githubusercontent.com",
		Builder:          "https://github.com/Mampiz/provenance-gate/.github/workflows/build-sign.yml@refs/heads/main",
		SourceRepository: "https://github.com/Mampiz/my-service",
	}

	if err := complete.Validate(); err != nil {
		t.Fatalf("a complete identity was rejected: %v", err)
	}

	// Each of these would silently turn the check into a no-op, which is the
	// failure mode worth having a test for: it looks like it is working.
	for name, mutate := range map[string]func(Identity) Identity{
		"no issuer":            func(i Identity) Identity { i.Issuer = ""; return i },
		"no builder":           func(i Identity) Identity { i.Builder = ""; return i },
		"no source repository": func(i Identity) Identity { i.SourceRepository = ""; return i },
	} {
		t.Run(name, func(t *testing.T) {
			if err := mutate(complete).Validate(); err == nil {
				t.Error("an incomplete identity was accepted, so nothing would be enforced")
			}
		})
	}
}

func TestIdentityMatch(t *testing.T) {
	want := Identity{
		Issuer:           "https://token.actions.githubusercontent.com",
		Builder:          "https://github.com/Mampiz/provenance-gate/.github/workflows/build-sign.yml@refs/heads/main",
		SourceRepository: "https://github.com/Mampiz/my-service",
		WorkflowPath:     ".github/workflows/release.yml",
		WorkflowRef:      "refs/heads/main",
	}
	good := Observed{
		SourceRepository: "https://github.com/Mampiz/my-service",
		WorkflowPath:     ".github/workflows/release.yml",
		WorkflowRef:      "refs/heads/main",
	}

	if err := want.Match(good); err != nil {
		t.Fatalf("the matching provenance was rejected: %v", err)
	}

	cases := map[string]struct {
		observed Observed
		mentions string
	}{
		// The case the whole project exists for: a real build, correctly signed,
		// by a workflow that belongs to somebody else's service.
		"another legitimate repository": {
			observed: Observed{
				SourceRepository: "https://github.com/Mampiz/some-other-service",
				WorkflowPath:     ".github/workflows/release.yml",
				WorkflowRef:      "refs/heads/main",
			},
			mentions: "some-other-service",
		},
		// Prefix matching on a repository URL is how an attacker's lookalike
		// repository gets accepted, so the comparison has to be exact.
		"a repository whose name starts the same": {
			observed: Observed{
				SourceRepository: "https://github.com/Mampiz/my-service-evil",
				WorkflowPath:     ".github/workflows/release.yml",
				WorkflowRef:      "refs/heads/main",
			},
			mentions: "my-service-evil",
		},
		"the right repository but the wrong workflow": {
			observed: Observed{
				SourceRepository: "https://github.com/Mampiz/my-service",
				WorkflowPath:     ".github/workflows/experiment.yml",
				WorkflowRef:      "refs/heads/main",
			},
			mentions: "experiment.yml",
		},
		"the right workflow on an unapproved branch": {
			observed: Observed{
				SourceRepository: "https://github.com/Mampiz/my-service",
				WorkflowPath:     ".github/workflows/release.yml",
				WorkflowRef:      "refs/heads/attacker-branch",
			},
			mentions: "attacker-branch",
		},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			err := want.Match(tc.observed)
			if err == nil {
				t.Fatal("the provenance was accepted, but it does not belong to this workload")
			}
			if !strings.Contains(err.Error(), tc.mentions) {
				t.Errorf("the rejection does not say what was wrong: %v", err)
			}
		})
	}
}

func TestIdentityMatchTreatsEmptyConstraintsAsUnconstrained(t *testing.T) {
	// A trust root that names only the repository accepts any workflow and any
	// ref of it. That is a weaker policy, not a broken one, and it has to keep
	// working so the fields can stay optional.
	want := Identity{
		Issuer:           "https://token.actions.githubusercontent.com",
		Builder:          "https://github.com/Mampiz/provenance-gate/.github/workflows/build-sign.yml@refs/heads/main",
		SourceRepository: "https://github.com/Mampiz/my-service",
	}
	observed := Observed{
		SourceRepository: "https://github.com/Mampiz/my-service",
		WorkflowPath:     ".github/workflows/anything.yml",
		WorkflowRef:      "refs/heads/some-branch",
	}
	if err := want.Match(observed); err != nil {
		t.Fatalf("unset constraints should not reject: %v", err)
	}
}
