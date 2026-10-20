package backup

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/vaulthalla/desktop/helpers/vaulthalla-1password/internal/store"
)

// SelfTest is the maintainer's manual check: connect to the account (1Password asks for approval), list vaults,
// and describe the Vaulthalla backup items if the vault exists. It is read-only: it never creates a vault, never
// writes an item and never reads a key value out of an item. Returns the process exit status.
func SelfTest(ctx context.Context, c store.Connector, account, vaultTitle string, out io.Writer) int {
	say := func(format string, args ...any) { fmt.Fprintf(out, format+"\n", args...) }
	fail := func(step string, err error) int {
		e := mapError(err, nil)
		say("FAIL  %s: %s [%s]", step, e.Message, e.Code)
		if e.Hint != "" {
			say("      %s", e.Hint)
		}
		if e.Detail != "" {
			say("      1Password said: %s", e.Detail)
		}
		return 1
	}

	say("....  connecting to 1Password account %q (approve in 1Password if asked)", account)
	b, err := c.Connect(ctx, account)
	if err != nil {
		return fail("connect", err)
	}
	vaults, err := b.ListVaults(ctx)
	if err != nil {
		return fail("list vaults", err)
	}
	noun := "vaults"
	if len(vaults) == 1 {
		noun = "vault"
	}
	say("ok    connected; %d %s visible", len(vaults), noun)

	var matches []store.Vault
	for _, v := range vaults {
		if v.Title == vaultTitle {
			matches = append(matches, v)
		}
	}
	switch len(matches) {
	case 0:
		say("ok    no vault titled %q yet (Vaulthalla Desktop creates it on the first sync; self-test doesn't)", vaultTitle)
		return 0
	case 1:
		say("ok    vault %q is %s", vaultTitle, matches[0].ID)
	default:
		say("WARN  %d vaults are titled %q; the app will ask which one to use", len(matches), vaultTitle)
		return 0
	}

	items, err := backups(ctx, b, matches[0].ID)
	if err != nil {
		return fail("list items", err)
	}
	say("ok    %d Vaulthalla backup items (metadata only, no key values read out)", len(items))
	for _, p := range items {
		m := p.meta()
		versions := make([]string, 0, len(m.Versions))
		for _, v := range m.Versions {
			versions = append(versions, fmt.Sprintf("v%d(%s)", v.Version, v.State))
		}
		say("      %s  node=%s vault=%s current=v%d versions=[%s]", m.ItemID, m.NodeName, m.VaultName,
			m.CurrentVersion, strings.Join(versions, " "))
		for _, issue := range m.Issues {
			say("      WARN %s", issue)
		}
	}
	return 0
}
