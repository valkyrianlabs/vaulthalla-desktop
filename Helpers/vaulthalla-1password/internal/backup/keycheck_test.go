package backup

import (
	"strings"
	"testing"

	"github.com/vaulthalla/desktop/helpers/vaulthalla-1password/internal/store"
)

// sequentialKey is the documented test key: bytes 00 01 … 1f.
func sequentialKey() []byte {
	k := make([]byte, 32)
	for i := range k {
		k[i] = byte(i)
	}
	return k
}

// The daemon's documented vectors (vault/KeyCheck.hpp, docs/vaults/secrets-and-key-export.md): the helper must
// match it byte for byte, or every backup would be refused or confirmed wrongly.
func TestKeyCheckMatchesTheDaemonsVectors(t *testing.T) {
	for _, c := range []struct {
		vault   string
		version int
		want    string
	}{
		{"42", 3, "72e4c8b7f8ab43b8ed8869a57cef1703"},
		{"1", 1, "c7a67cdafd3140b29e19b0b5e543cb13"},
	} {
		got, ok := KeyCheck(sequentialKey(), c.vault, c.version)
		if !ok || got != c.want {
			t.Errorf("vault %s version %d: got %q (ok %v), want %q", c.vault, c.version, got, ok, c.want)
		}
	}
}

func TestKeyCheckBindsVaultVersionAndKey(t *testing.T) {
	base, _ := KeyCheck(sequentialKey(), "42", 3)
	other := sequentialKey()
	other[31] ^= 1
	for name, got := range map[string]func() (string, bool){
		"other vault":   func() (string, bool) { return KeyCheck(sequentialKey(), "43", 3) },
		"other version": func() (string, bool) { return KeyCheck(sequentialKey(), "42", 4) },
		"other key":     func() (string, bool) { return KeyCheck(other, "42", 3) },
	} {
		if c, ok := got(); !ok || c == base {
			t.Errorf("%s: %q (ok %v) must differ from %q", name, c, ok, base)
		}
	}
	for name, bad := range map[string]func() (string, bool){
		"short key":     func() (string, bool) { return KeyCheck(sequentialKey()[:16], "42", 3) },
		"leading zero":  func() (string, bool) { return KeyCheck(sequentialKey(), "042", 3) },
		"signed vault":  func() (string, bool) { return KeyCheck(sequentialKey(), "+42", 3) },
		"empty vault":   func() (string, bool) { return KeyCheck(sequentialKey(), "", 3) },
		"zero version":  func() (string, bool) { return KeyCheck(sequentialKey(), "42", 0) },
		"version > u32": func() (string, bool) { return KeyCheck(sequentialKey(), "42", 1<<32) },
	} {
		if _, ok := bad(); ok {
			t.Errorf("%s: accepted", name)
		}
	}
	if c, ok := KeyCheck(sequentialKey(), "0", 1); !ok || len(c) != 32 || strings.ToLower(c) != c {
		t.Errorf("vault 0: %q %v", c, ok)
	}
}

func TestUpsertRefusesAMismatchedKeyCheckAndWritesNothing(t *testing.T) {
	h, vaultID := connected(t)
	var first UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 1, v(1, 1)), &first)
	writes := h.mem.Writes

	cases := map[string]ver{
		"check of another key":     {Version: 2, Key: b64(key(2)), KeyCheck: kc(2, 3), Needed: true},
		"check of another version": {Version: 2, Key: b64(key(2)), KeyCheck: kc(1, 2), Needed: true},
		"check of another vault":   {Version: 2, Key: b64(key(2)), KeyCheck: kcFor("43", 2, 2), Needed: true},
		"not a check at all":       {Version: 2, Key: b64(key(2)), KeyCheck: "check-2-2", Needed: true},
	}
	for name, bad := range cases {
		t.Run(name, func(t *testing.T) {
			e := h.fails("item.upsert", upsertParams(vaultID, 2, bad, v(1, 1)), CodeKeyCheckMismatch)
			if e.Hint == "" || strings.Contains(e.Message, b64(key(2))) {
				t.Fatalf("error %+v", e)
			}
		})
	}
	// One bad version among good ones refuses the whole request.
	h.fails("item.upsert", upsertParams(vaultID, 3, v(3, 3), cases["check of another key"], v(1, 1)), CodeKeyCheckMismatch)

	if h.mem.Writes != writes {
		t.Fatal("a refused upsert wrote to 1Password")
	}
	it := h.item(vaultID, first.ItemID)
	if _, ok := it.Field(SectionVersions, "v2"); ok {
		t.Fatal("a refused version was stored")
	}
}

// D6: a version still needed for restoration is never overwritten or dropped, whatever later upserts carry.
func TestVersionsAreNeverDropped(t *testing.T) {
	h, vaultID := connected(t)
	var res UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 1, v(1, 1)), &res)
	h.ok("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), &res) // mid-rotation: both needed
	h.ok("item.upsert", upsertParams(vaultID, 3, v(3, 3), v(2, 2)), &res) // v1 no longer listed
	h.ok("item.upsert", upsertParams(vaultID, 4, v(4, 4)), &res)          // only the current one
	// An upsert that lists an old version with other bytes changes nothing.
	h.fails("item.upsert", upsertParams(vaultID, 4, v(4, 4), ver{Version: 1, Key: b64(key(9)), KeyCheck: kc(1, 9), Needed: true}),
		CodeVersionConflict)

	var list ItemsListResult
	h.ok("items.list", map[string]string{"vault_id": vaultID}, &list)
	if len(list.Items) != 1 {
		t.Fatalf("items %+v", list.Items)
	}
	got := list.Items[0]
	want := []VersionMeta{{Version: 4, KeyCheck: kc(4, 4), State: StateCurrent}, {Version: 3, KeyCheck: kc(3, 3), State: StateRetired}, {Version: 2, KeyCheck: kc(2, 2), State: StateRetired}, {Version: 1, KeyCheck: kc(1, 1), State: StateRetired}}
	if got.CurrentVersion != 4 || got.KeyCheck != kc(4, 4) || len(got.Issues) != 0 || len(got.Versions) != len(want) {
		t.Fatalf("meta %+v", got)
	}
	for i := range want {
		if got.Versions[i] != want[i] {
			t.Fatalf("versions %+v, want %+v", got.Versions, want)
		}
	}
	it := h.item(vaultID, res.ItemID)
	for n := 1; n <= 4; n++ {
		if field(t, it, SectionVersions, versionField(n)) != b64(key(byte(n))) {
			t.Fatalf("v%d changed or lost", n)
		}
	}

	// And every version comes back out for a restore, each verified against its check.
	var revealed struct {
		Versions []struct {
			Version int    `json:"version"`
			Key     []byte `json:"key_b64"`
		} `json:"versions"`
	}
	h.ok("item.reveal", map[string]any{"vault_id": vaultID, "item_id": res.ItemID}, &revealed)
	if len(revealed.Versions) != 4 {
		t.Fatalf("revealed %d versions", len(revealed.Versions))
	}
}

func tamper(t *testing.T, h *harness, vaultID, itemID, fieldID string, value string) {
	t.Helper()
	it := h.item(vaultID, itemID)
	found := false
	for i, f := range it.Fields {
		if f.ID == fieldID {
			it.Fields[i].Value = value
			found = true
		}
	}
	if !found {
		t.Fatalf("no field %s", fieldID)
	}
	h.mem.Put(it)
}

func TestStoredKeysAreCheckedOnListAndReveal(t *testing.T) {
	h, vaultID := connected(t)
	var res UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), &res)
	// Someone pastes another key into v1 and leaves its check: the item says v1 is key(1), but it isn't.
	tamper(t, h, vaultID, res.ItemID, "v1", b64(key(8)))

	var list ItemsListResult
	h.ok("items.list", map[string]string{"vault_id": vaultID}, &list)
	if len(list.Items) != 1 || !strings.Contains(strings.Join(list.Items[0].Issues, ";"), "v1 doesn't match its key check") {
		t.Fatalf("issues %+v", list.Items)
	}
	h.fails("item.reveal", map[string]any{"vault_id": vaultID, "item_id": res.ItemID}, CodeKeyCheckMismatch)
	h.fails("item.reveal", map[string]any{"vault_id": vaultID, "item_id": res.ItemID, "versions": []int{1}}, CodeKeyCheckMismatch)
	// The untouched version still reveals on its own.
	h.ok("item.reveal", map[string]any{"vault_id": vaultID, "item_id": res.ItemID, "versions": []int{2}}, nil)
}

func TestUpsertRecomputesKeyChecksOnReadBack(t *testing.T) {
	h, vaultID := connected(t)
	var res UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 1, v(1, 1)), &res)
	// A retired-looking v5 nobody sent, holding a key that isn't what its check says: an upsert that adds v2 must
	// not confirm an item like that.
	it := h.item(vaultID, res.ItemID)
	it.Fields = append(it.Fields,
		fieldOf(SectionVersions, "v5", b64(key(5))), fieldOf(SectionVersions, "v5_check", kc(5, 6)),
		fieldOf(SectionVersions, "v5_state", StateRetired))
	h.mem.Put(it)
	e := h.fails("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), CodeVerifyFailed)
	if !strings.Contains(e.Message, "v5 doesn't match its key check") {
		t.Fatalf("message %q", e.Message)
	}
}

func fieldOf(section, id, value string) store.Field {
	return store.Field{ID: id, Title: id, SectionID: section, Type: store.FieldText, Value: value}
}
