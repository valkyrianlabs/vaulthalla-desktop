package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"

	"github.com/valkyrianlabs/vaulthalla-desktop/helpers/vaulthalla-1password/internal/backup"
	"github.com/valkyrianlabs/vaulthalla-desktop/helpers/vaulthalla-1password/internal/opsdk"
)

const sdkModule = "github.com/1password/onepassword-sdk-go"

func sdkVersion() string {
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, dep := range info.Deps {
			if dep.Path == sdkModule {
				return dep.Version
			}
		}
	}
	return "unknown"
}

func cgoEnabled() string {
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, s := range info.Settings {
			if s.Key == "CGO_ENABLED" {
				return s.Value
			}
		}
	}
	return "unknown"
}

// selfTest runs backup.SelfTest against the real 1Password app. Run it by hand; it may show a 1Password approval
// prompt (Touch ID). It is read-only.
func selfTest(ctx context.Context, args []string, out io.Writer) int {
	fs := flag.NewFlagSet("self-test", flag.ContinueOnError)
	account := fs.String("account", "", "1Password account name as shown at the top of the app's sidebar, or its ID")
	vault := fs.String("vault", "Vaulthalla", "title of the backup vault to inspect")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *account == "" {
		fmt.Fprintln(os.Stderr, "self-test: --account is required")
		return 2
	}

	fmt.Fprintf(out, "vaulthalla-1password %s, 1Password Go SDK %s, CGO_ENABLED=%s, %s/%s\n",
		version, sdkVersion(), cgoEnabled(), runtime.GOOS, runtime.GOARCH)
	if runtime.GOOS == "darwin" {
		found := false
		home, _ := os.UserHomeDir()
		for _, dir := range []string{"/Applications", filepath.Join(home, "Applications")} {
			lib := filepath.Join(dir, "1Password.app/Contents/Frameworks/libop_sdk_ipc_client.dylib")
			if _, err := os.Stat(lib); err == nil {
				fmt.Fprintf(out, "ok    found %s\n", lib)
				found = true
				break
			}
		}
		if !found {
			fmt.Fprintln(out, "WARN  1Password's libop_sdk_ipc_client.dylib wasn't found in /Applications or ~/Applications")
		}
	}
	return backup.SelfTest(ctx, opsdk.Connector{Version: version}, *account, *vault, out)
}
