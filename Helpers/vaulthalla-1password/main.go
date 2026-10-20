// vaulthalla-1password backs up Vaulthalla vault keys to 1Password for Vaulthalla Desktop.
//
// Usage:
//
//	vaulthalla-1password                          serve the JSON-lines protocol on stdin/stdout (what the app runs)
//	vaulthalla-1password self-test --account NAME read-only connectivity check, run by hand
//	vaulthalla-1password version
//
// Key bytes arrive only on stdin and leave only on stdout: never in argv, the environment, files or logs. stderr
// carries redacted diagnostics (op names, ids, error codes, timings). The process exits when stdin closes.
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/vaulthalla/desktop/helpers/vaulthalla-1password/internal/backup"
	"github.com/vaulthalla/desktop/helpers/vaulthalla-1password/internal/opsdk"
)

// version is stamped by build.sh (-ldflags "-X main.version=...").
var version = "dev"

func main() {
	// SIGTERM/SIGINT keep their default action (exit at once): the app terminates a helper that is stuck, e.g.
	// behind a 1Password prompt nobody answered, and a cgo call into 1Password's library can't be interrupted.
	ctx := context.Background()

	args := os.Args[1:]
	if len(args) > 0 {
		switch args[0] {
		case "version", "--version", "-v":
			fmt.Printf("vaulthalla-1password %s (1Password Go SDK %s%s)\n", version, sdkVersion(), buildFlavor())
			return
		case "self-test":
			os.Exit(selfTest(ctx, args[1:], os.Stdout))
		case "help", "--help", "-h":
			fmt.Println("usage: vaulthalla-1password [self-test --account NAME | version]")
			return
		default:
			fmt.Fprintln(os.Stderr, "usage: vaulthalla-1password [self-test --account NAME | version]")
			os.Exit(2)
		}
	}

	server := &backup.Server{
		Connector: opsdk.Connector{Version: version},
		Log:       os.Stderr,
	}
	if fakeSetup(server) {
		fmt.Fprintln(os.Stderr, "vaulthalla-1password: FAKE MODE (in-memory 1Password, test build)")
	}
	if err := server.Serve(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "vaulthalla-1password: i/o error:", err)
		os.Exit(1)
	}
}
