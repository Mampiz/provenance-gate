// Package version carries the build identity of the binary.
//
// The values are injected at link time by the Makefile. They are variables
// rather than constants precisely so that -ldflags -X can set them, and they
// default to "dev" so a plain "go build" still produces something that runs.
package version

import (
	"fmt"
	"runtime"
)

var (
	// Version is the release this binary was built from.
	Version = "dev"
	// Commit is the git revision, with a "-dirty" suffix when the tree was not clean.
	Commit = "unknown"
	// BuildDate is the RFC 3339 timestamp of the build.
	BuildDate = "unknown"
)

// String renders the build identity on one line.
func String() string {
	return fmt.Sprintf("provenance-gate %s (commit %s, built %s, %s)",
		Version, Commit, BuildDate, runtime.Version())
}
