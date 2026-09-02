package version

import (
	"strings"
	"testing"
)

// The build identity is what the -version flag prints and what every log line
// is correlated against, so each field has to survive into the output even when
// nothing was injected at link time.
func TestStringCarriesEveryField(t *testing.T) {
	got := String()
	for name, want := range map[string]string{
		"Version":   Version,
		"Commit":    Commit,
		"BuildDate": BuildDate,
	} {
		if want == "" {
			t.Fatalf("%s defaulted to the empty string", name)
		}
		if !strings.Contains(got, want) {
			t.Errorf("String() = %q, missing %s %q", got, name, want)
		}
	}
	if !strings.HasPrefix(got, "provenance-gate ") {
		t.Errorf("String() = %q, want it to name the binary first", got)
	}
}
