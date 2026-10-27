//go:build !fake

package main

import (
	"testing"

	"github.com/valkyrianlabs/vaulthalla-desktop/helpers/vaulthalla-1password/internal/backup"
)

// A release build can't be switched into fake mode from the environment.
func TestReleaseBuildIgnoresFakeEnvironment(t *testing.T) {
	t.Setenv("VH_OP_FAKE", "1")
	s := &backup.Server{}
	if fakeSetup(s) || s.Connector != nil || s.Extra != nil {
		t.Fatal("release build entered fake mode")
	}
}
