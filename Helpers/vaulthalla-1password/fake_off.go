//go:build !fake

package main

import "github.com/valkyrianlabs/vaulthalla-desktop/helpers/vaulthalla-1password/internal/backup"

// fakeSetup is a no-op in release builds: VH_OP_FAKE is ignored, and the in-memory store and fault-injection ops
// aren't linked in. Only `go build -tags fake` (the Swift tests) can switch the helper into fake mode.
func fakeSetup(*backup.Server) bool { return false }

func buildFlavor() string { return "" }
