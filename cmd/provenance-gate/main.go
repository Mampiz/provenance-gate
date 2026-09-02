// Command provenance-gate is the admission webhook that ties a workload to the
// build that produced it.
//
// At this phase it does nothing but report its own build identity: the point of
// F0 is that the module, the toolchain and the cluster bring-up are real and
// reproducible before any verification logic exists. The admission server is
// added in F3.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/Mampiz/provenance-gate/internal/version"
)

func main() {
	showVersion := flag.Bool("version", false, "print the build identity and exit")
	flag.Parse()

	if *showVersion {
		fmt.Println(version.String())
		return
	}

	fmt.Fprintln(os.Stderr, version.String())
	fmt.Fprintln(os.Stderr, "no admission server in this build: see docs/decisions and PROGRESS.md")
}
