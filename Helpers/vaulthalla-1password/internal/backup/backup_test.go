package backup

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/valkyrianlabs/vaulthalla-desktop/helpers/vaulthalla-1password/internal/store"
)

// --- harness ---

type harness struct {
	t      *testing.T
	mem    *store.Memory
	server *Server
	log    bytes.Buffer
	nextID int
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	h := &harness{t: t, mem: store.NewMemory()}
	h.server = &Server{Connector: h.mem, Log: &h.log, Now: func() time.Time { return time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC) }}
	return h
}

type response struct {
	ID     json.RawMessage `json:"id"`
	OK     bool            `json:"ok"`
	Result json.RawMessage `json:"result"`
	Error  *Error          `json:"error"`
	raw    string
}

// send runs raw request lines through Serve and returns one response per line.
func (h *harness) send(lines ...string) []response {
	h.t.Helper()
	var out bytes.Buffer
	in := strings.NewReader(strings.Join(lines, "\n") + "\n")
	if err := h.server.Serve(context.Background(), in, &out); err != nil {
		h.t.Fatalf("Serve: %v", err)
	}
	var res []response
	for _, line := range strings.Split(strings.TrimSuffix(out.String(), "\n"), "\n") {
		if line == "" {
			continue
		}
		var r response
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			h.t.Fatalf("response isn't JSON: %q", line)
		}
		r.raw = line
		res = append(res, r)
	}
	return res
}

// call sends one op and returns its response.
func (h *harness) call(op string, params any) response {
	h.t.Helper()
	h.nextID++
	p, err := json.Marshal(params)
	if err != nil {
		h.t.Fatal(err)
	}
	line := fmt.Sprintf(`{"id":%d,"op":%q,"params":%s}`, h.nextID, op, p)
	res := h.send(line)
	if len(res) != 1 {
		h.t.Fatalf("%s: want 1 response, got %d", op, len(res))
	}
	if string(res[0].ID) != fmt.Sprint(h.nextID) {
		h.t.Fatalf("%s: response id %s, want %d", op, res[0].ID, h.nextID)
	}
	return res[0]
}

func (h *harness) ok(op string, params any, into any) response {
	h.t.Helper()
	r := h.call(op, params)
	if !r.OK {
		h.t.Fatalf("%s failed: %+v", op, r.Error)
	}
	if into != nil {
		if err := json.Unmarshal(r.Result, into); err != nil {
			h.t.Fatalf("%s result: %v", op, err)
		}
	}
	return r
}

func (h *harness) fails(op string, params any, code string) *Error {
	h.t.Helper()
	r := h.call(op, params)
	if r.OK || r.Error == nil {
		h.t.Fatalf("%s: want error %s, got ok: %s", op, code, r.raw)
	}
	if r.Error.Code != code {
		h.t.Fatalf("%s: want error %s, got %+v", op, code, r.Error)
	}
	return r.Error
}

// connected returns a harness with a session and the Vaulthalla vault.
func connected(t *testing.T) (*harness, string) {
	h := newHarness(t)
	h.ok("account.check", map[string]string{"account": "Cooper"}, nil)
	var v VaultResult
	h.ok("vault.ensure", map[string]string{"title": "Vaulthalla"}, &v)
	return h, v.VaultID
}

func key(n byte) []byte { return bytes.Repeat([]byte{n}, 32) }

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

type ver struct {
	Version  int    `json:"version"`
	Key      string `json:"key_b64"`
	KeyCheck string `json:"key_check"`
	Needed   bool   `json:"needed"`
	// Attestation metadata (attestation_test.go).
	Attestation *Attestation `json:"attestation,omitempty"`
}

// testVault is the Vaulthalla vault the tests back up (vault_uuid: the vault's numeric id, as the key check binds it).
const testVault = "42"

// kc is the key check of key(k) as version n of testVault.
func kc(n int, k byte) string { return kcFor(testVault, n, k) }

func kcFor(vault string, n int, k byte) string {
	c, ok := KeyCheck(key(k), vault, n)
	if !ok {
		return "not-a-check" // inputs KeyCheck refuses (version 0): the request is invalid anyway
	}
	return c
}

func v(n int, k byte) ver {
	return ver{Version: n, Key: b64(key(k)), KeyCheck: kc(n, k), Needed: true}
}

func upsertParams(vaultID string, current int, versions ...ver) map[string]any {
	return map[string]any{
		"vault_id": vaultID, "node_id": "node-1", "node_name": "Home Lab", "vault_uuid": testVault,
		"vault_name": "Photos", "versions": versions, "current_version": current,
	}
}

func (h *harness) item(vaultID, itemID string) store.Item {
	h.t.Helper()
	it, err := h.mem.GetItem(context.Background(), vaultID, itemID)
	if err != nil {
		h.t.Fatal(err)
	}
	return it
}

func field(t *testing.T, it store.Item, section, id string) string {
	t.Helper()
	f, ok := it.Field(section, id)
	if !ok {
		t.Fatalf("item has no field %s/%s", section, id)
	}
	return f.Value
}

// --- account.check ---

func TestAccountCheckConnects(t *testing.T) {
	h := newHarness(t)
	h.mem.AddVault("Personal")
	var res AccountResult
	h.ok("account.check", map[string]string{"account": "Cooper"}, &res)
	if !res.Connected || res.VaultCount != 1 || res.Account != "Cooper" {
		t.Fatalf("unexpected result %+v", res)
	}
}

func TestAccountCheckMapsDesktopIntegrationFailures(t *testing.T) {
	for scenario := range store.ScenarioMessages {
		t.Run(scenario, func(t *testing.T) {
			h := newHarness(t)
			e := h.fails("account.check", map[string]string{"account": "fake:" + scenario}, scenario)
			if e.Hint == "" || e.Message == "" {
				t.Fatalf("missing message or hint: %+v", e)
			}
		})
	}
	h := newHarness(t)
	e := h.fails("account.check", map[string]string{"account": "fake:integration_disabled"}, CodeIntegrationDisabled)
	if !strings.Contains(e.Hint, "Settings → Developer") || !strings.Contains(e.Hint, "Integrate with other apps") {
		t.Fatalf("hint doesn't say where the setting is: %q", e.Hint)
	}
}

func TestOpsNeedASession(t *testing.T) {
	h := newHarness(t)
	h.fails("vault.ensure", map[string]string{"title": "Vaulthalla"}, CodeNoSession)
	h.fails("items.list", map[string]string{"vault_id": "x"}, CodeNoSession)
	h.fails("item.reveal", map[string]string{"vault_id": "x", "item_id": "y"}, CodeNoSession)
	h.fails("item.upsert", upsertParams("x", 1, v(1, 1)), CodeNoSession)
	h.fails("item.attest", map[string]any{"vault_id": "x", "item_id": "y", "node_id": "n", "vault_uuid": testVault,
		"versions": []map[string]any{{"version": 1, "key_check": kc(1, 1),
			"attestation": map[string]any{"key_id": 1, "signature": b64(bytes.Repeat([]byte{1}, 64))}}}}, CodeNoSession)
}

func TestAccountSwitchIsRefused(t *testing.T) {
	h := newHarness(t)
	h.ok("account.check", map[string]string{"account": "Cooper"}, nil)
	h.ok("account.check", map[string]string{"account": "Cooper"}, nil)
	h.fails("account.check", map[string]string{"account": "Work"}, CodeAccountSwitch)
}

// --- vault.ensure ---

func TestVaultEnsureCreatesOnceThenFinds(t *testing.T) {
	h := newHarness(t)
	h.ok("account.check", map[string]string{"account": "Cooper"}, nil)
	var first, second VaultResult
	h.ok("vault.ensure", map[string]string{"title": "Vaulthalla"}, &first)
	h.ok("vault.ensure", map[string]string{"title": "Vaulthalla"}, &second)
	if !first.Created || second.Created || first.VaultID != second.VaultID || first.VaultID == "" {
		t.Fatalf("first %+v second %+v", first, second)
	}
	vaults, _ := h.mem.ListVaults(context.Background())
	if len(vaults) != 1 {
		t.Fatalf("want 1 vault, got %d", len(vaults))
	}
}

func TestVaultEnsureRefusesAmbiguousTitles(t *testing.T) {
	h := newHarness(t)
	h.mem.AddVault("Vaulthalla")
	h.mem.AddVault("Vaulthalla")
	h.ok("account.check", map[string]string{"account": "Cooper"}, nil)
	h.fails("vault.ensure", map[string]string{"title": "Vaulthalla"}, CodeAmbiguousVault)
}

// --- item.upsert ---

func TestUpsertCreatesTheItemLayout(t *testing.T) {
	h, vaultID := connected(t)
	var res UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 1, v(1, 1)), &res)
	if !res.Created || !res.Written || res.CurrentVersion != 1 || res.KeyCheck != kc(1, 1) {
		t.Fatalf("unexpected result %+v", res)
	}
	if len(res.StoredVersions) != 1 || res.StoredVersions[0] != (VersionMeta{Version: 1, KeyCheck: kc(1, 1), State: StateCurrent}) {
		t.Fatalf("stored versions %+v", res.StoredVersions)
	}

	it := h.item(vaultID, res.ItemID)
	if it.Category != store.CategoryAPICredentials {
		t.Fatalf("category %s", it.Category)
	}
	if it.Title != "Vaulthalla · Photos · Home Lab" {
		t.Fatalf("title %q", it.Title)
	}
	cred, _ := it.Field("", FieldCredential)
	if cred.Type != store.FieldConcealed || cred.Value != b64(key(1)) {
		t.Fatalf("credential %+v", cred)
	}
	for id, want := range map[string]string{FieldNodeID: "node-1", FieldNodeName: "Home Lab", FieldVaultUUID: testVault,
		FieldVaultName: "Photos", FieldKeyVersion: "1", FieldKeyCheck: kc(1, 1), FieldFormat: Format,
		FieldBackedUpAt: "2026-10-20T12:00:00Z"} {
		if got := field(t, it, SectionMeta, id); got != want {
			t.Errorf("%s = %q, want %q", id, got, want)
		}
	}
	v1, _ := it.Field(SectionVersions, "v1")
	if v1.Type != store.FieldConcealed || v1.Value != b64(key(1)) {
		t.Fatalf("v1 %+v", v1)
	}
	if field(t, it, SectionVersions, "v1_check") != kc(1, 1) || field(t, it, SectionVersions, "v1_state") != StateCurrent {
		t.Fatal("v1 check/state")
	}
	if strings.Join(it.Tags, ",") != "vaulthalla,vaulthalla/home-lab" {
		t.Fatalf("tags %v", it.Tags)
	}
	titles := map[string]string{}
	for _, s := range it.Sections {
		titles[s.ID] = s.Title
	}
	if titles[SectionMeta] != "Vaulthalla" || titles[SectionVersions] != "Key versions" {
		t.Fatalf("sections %+v", it.Sections)
	}
	if !strings.Contains(it.Notes, "To restore") {
		t.Fatalf("notes %q", it.Notes)
	}
}

func TestUpsertAddsANewVersionAndMovesTheCredential(t *testing.T) {
	h, vaultID := connected(t)
	var first, second UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 1, v(1, 1)), &first)
	h.ok("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), &second)
	if second.Created || !second.Written || second.ItemID != first.ItemID || second.CurrentVersion != 2 || second.KeyCheck != kc(2, 2) {
		t.Fatalf("second %+v", second)
	}
	want := []VersionMeta{{Version: 2, KeyCheck: kc(2, 2), State: StateCurrent}, {Version: 1, KeyCheck: kc(1, 1), State: StateNeeded}}
	if fmt.Sprint(second.StoredVersions) != fmt.Sprint(want) {
		t.Fatalf("stored %+v", second.StoredVersions)
	}
	it := h.item(vaultID, first.ItemID)
	if field(t, it, "", FieldCredential) != b64(key(2)) || field(t, it, SectionVersions, "v1") != b64(key(1)) ||
		field(t, it, SectionVersions, "v2") != b64(key(2)) || field(t, it, SectionMeta, FieldKeyVersion) != "2" {
		t.Fatal("versions not stored as expected")
	}
	// Newest first in the section.
	var order []string
	for _, f := range it.Fields {
		if f.SectionID == SectionVersions && versionFieldID.MatchString(f.ID) {
			order = append(order, f.ID)
		}
	}
	if strings.Join(order, ",") != "v2,v1" {
		t.Fatalf("order %v", order)
	}
}

func TestUpsertRefusesToOverwriteAStoredVersion(t *testing.T) {
	h, vaultID := connected(t)
	var first UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 1, v(1, 1)), &first)
	writes := h.mem.Writes

	// Same version number, different key: never overwritten.
	e := h.fails("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 9)), CodeVersionConflict)
	if e.Hint == "" {
		t.Fatal("conflict has no hint")
	}
	// Same key, a key check that doesn't match it: refused before 1Password is touched.
	bad := v(1, 1)
	bad.KeyCheck = kc(1, 2)
	h.fails("item.upsert", upsertParams(vaultID, 1, bad), CodeKeyCheckMismatch)

	if h.mem.Writes != writes {
		t.Fatal("a refused upsert wrote to 1Password")
	}
	it := h.item(vaultID, first.ItemID)
	if field(t, it, SectionVersions, "v1") != b64(key(1)) || field(t, it, "", FieldCredential) != b64(key(1)) {
		t.Fatal("stored version changed")
	}
	if _, ok := it.Field(SectionVersions, "v2"); ok {
		t.Fatal("a refused upsert added a version")
	}
}

func TestUpsertIsIdempotent(t *testing.T) {
	h, vaultID := connected(t)
	var first, again UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), &first)
	writes := h.mem.Writes
	before := h.item(vaultID, first.ItemID)
	h.ok("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), &again)
	if again.Written || again.Created || again.ItemID != first.ItemID || h.mem.Writes != writes {
		t.Fatalf("re-upsert wrote: %+v (writes %d → %d)", again, writes, h.mem.Writes)
	}
	if after := h.item(vaultID, first.ItemID); after.Version != before.Version {
		t.Fatal("item version changed")
	}
	if fmt.Sprint(again.StoredVersions) != fmt.Sprint(first.StoredVersions) {
		t.Fatal("results differ")
	}
}

func TestUpsertKeepsVersionsTheDaemonNoLongerLists(t *testing.T) {
	h, vaultID := connected(t)
	var res UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), &res)
	h.ok("item.upsert", upsertParams(vaultID, 3, v(3, 3)), &res) // the daemon finished re-encrypting: only v3
	want := []VersionMeta{{Version: 3, KeyCheck: kc(3, 3), State: StateCurrent}, {Version: 2, KeyCheck: kc(2, 2), State: StateRetired}, {Version: 1, KeyCheck: kc(1, 1), State: StateRetired}}
	if fmt.Sprint(res.StoredVersions) != fmt.Sprint(want) {
		t.Fatalf("stored %+v", res.StoredVersions)
	}
	it := h.item(vaultID, res.ItemID)
	if field(t, it, SectionVersions, "v1") != b64(key(1)) || field(t, it, SectionVersions, "v2") != b64(key(2)) {
		t.Fatal("old versions lost")
	}
}

func TestUpsertMatchesOnIdentifiersNotTitle(t *testing.T) {
	h, vaultID := connected(t)
	// A foreign item with the very title the helper would use, but no identifiers: never touched.
	foreign := h.mem.Put(store.Item{VaultID: vaultID, Category: store.CategoryAPICredentials, Title: "Vaulthalla · Photos · Home Lab",
		Fields: []store.Field{{ID: "credential", Type: store.FieldConcealed, Value: "user's own"}}})
	var first UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 1, v(1, 1)), &first)
	if first.ItemID == foreign.ID || !first.Created {
		t.Fatal("matched an item by title")
	}

	// Rename the node and the vault: same item, new title and tag.
	p := upsertParams(vaultID, 1, v(1, 1))
	p["node_name"], p["vault_name"] = "Basement", "Pictures"
	var renamed UpsertResult
	h.ok("item.upsert", p, &renamed)
	if renamed.ItemID != first.ItemID || renamed.Created || !renamed.Written {
		t.Fatalf("rename: %+v", renamed)
	}
	it := h.item(vaultID, first.ItemID)
	if it.Title != "Vaulthalla · Pictures · Basement" || strings.Join(it.Tags, ",") != "vaulthalla,vaulthalla/basement" {
		t.Fatalf("title %q tags %v", it.Title, it.Tags)
	}
	if h.item(vaultID, foreign.ID).Fields[0].Value != "user's own" {
		t.Fatal("foreign item changed")
	}
}

func TestUpsertKeepsFieldsAndTagsItDoesNotOwn(t *testing.T) {
	h, vaultID := connected(t)
	var res UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 1, v(1, 1)), &res)
	it := h.item(vaultID, res.ItemID)
	it.Fields = append(it.Fields, store.Field{ID: "mine", Title: "my note", SectionID: SectionVersions, Type: store.FieldText, Value: "keep"},
		store.Field{ID: "other", Title: "other", Type: store.FieldText, Value: "keep too"})
	it.Tags = append(it.Tags, "personal")
	it.Notes = "edited notes"
	h.mem.Put(it)

	h.ok("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), &res)
	it = h.item(vaultID, res.ItemID)
	if field(t, it, SectionVersions, "mine") != "keep" || field(t, it, "", "other") != "keep too" || it.Notes != "edited notes" {
		t.Fatal("foreign fields or notes lost")
	}
	if !strings.Contains(strings.Join(it.Tags, ","), "personal") {
		t.Fatalf("tags %v", it.Tags)
	}
}

func TestUpsertRefusesDuplicateItems(t *testing.T) {
	h, vaultID := connected(t)
	var res UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 1, v(1, 1)), &res)
	dup := h.item(vaultID, res.ItemID)
	dup.ID = ""
	h.mem.Put(dup)
	h.fails("item.upsert", upsertParams(vaultID, 1, v(1, 1)), CodeDuplicateItem)
}

func TestUpsertMapsConcurrentModificationAndScrubsSecrets(t *testing.T) {
	h, vaultID := connected(t)
	var res UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 1, v(1, 1)), &res)
	h.mem.FailPut = errors.New("incorrect item version")
	h.fails("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), CodeConcurrentModification)

	// An error that echoes a key value never carries it out.
	h.mem.FailPut = fmt.Errorf("validation error: field value %s is invalid", b64(key(2)))
	e := h.fails("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), CodeOnePassword)
	if strings.Contains(e.Detail, b64(key(2))) || !strings.Contains(e.Detail, "[redacted]") {
		t.Fatalf("detail not scrubbed: %q", e.Detail)
	}
}

// droppingBackend loses a version on write, so read-back verification must catch it.
type droppingBackend struct{ *store.Memory }

func (d droppingBackend) PutItem(ctx context.Context, it store.Item) (store.Item, error) {
	c := it.Clone()
	c.Fields = c.Fields[:0]
	for _, f := range it.Fields {
		if f.ID != "v2" {
			c.Fields = append(c.Fields, f)
		}
	}
	return d.Memory.PutItem(ctx, c)
}

type droppingConnector struct{ *store.Memory }

func (d droppingConnector) Connect(context.Context, string) (store.Backend, error) {
	return droppingBackend{d.Memory}, nil
}

func TestUpsertVerifiesTheReadBack(t *testing.T) {
	h, vaultID := connected(t)
	var res UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 1, v(1, 1)), &res)
	h.server.Connector, h.server.backend = droppingConnector{h.mem}, droppingBackend{h.mem}
	h.fails("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), CodeVerifyFailed)
}

func TestUpsertValidatesParams(t *testing.T) {
	h, vaultID := connected(t)
	cases := map[string]map[string]any{
		"no versions":        upsertParams(vaultID, 1),
		"current not listed": upsertParams(vaultID, 2, v(1, 1)),
		"duplicate version":  upsertParams(vaultID, 1, v(1, 1), v(1, 1)),
		"zero version":       upsertParams(vaultID, 0, v(0, 1)),
		"empty key":          upsertParams(vaultID, 1, ver{Version: 1, Key: "", KeyCheck: "c"}),
		"bad base64":         upsertParams(vaultID, 1, ver{Version: 1, Key: "not base64!", KeyCheck: "c"}),
		"no key check":       upsertParams(vaultID, 1, ver{Version: 1, Key: b64(key(1))}),
		"oversize key":       upsertParams(vaultID, 1, ver{Version: 1, Key: b64(bytes.Repeat([]byte{1}, 2000)), KeyCheck: "c"}),
		"short key":          upsertParams(vaultID, 1, ver{Version: 1, Key: b64(bytes.Repeat([]byte{1}, 16)), KeyCheck: "c"}),
		"vault id not a number": func() map[string]any {
			p := upsertParams(vaultID, 1, v(1, 1))
			p["vault_uuid"] = "vault-uuid-1"
			return p
		}(),
		"vault id leading zero": func() map[string]any { p := upsertParams(vaultID, 1, v(1, 1)); p["vault_uuid"] = "042"; return p }(),
		"control chars in name": func() map[string]any { p := upsertParams(vaultID, 1, v(1, 1)); p["node_name"] = "a\nb"; return p }(),
		"missing node id":       func() map[string]any { p := upsertParams(vaultID, 1, v(1, 1)); delete(p, "node_id"); return p }(),
		"unknown field":         func() map[string]any { p := upsertParams(vaultID, 1, v(1, 1)); p["title"] = "x"; return p }(),
		"wrong type":            func() map[string]any { p := upsertParams(vaultID, 1, v(1, 1)); p["current_version"] = "1"; return p }(),
	}
	for name, p := range cases {
		t.Run(name, func(t *testing.T) {
			e := h.fails("item.upsert", p, CodeBadRequest)
			if strings.Contains(e.Message, b64(key(1))) || strings.Contains(e.Message, "not base64!") {
				t.Fatalf("message echoes input: %q", e.Message)
			}
		})
	}
	nested := `{"id":1,"op":"item.upsert","params":{"vault_id":"` + vaultID + `","node_id":"n","node_name":"n","vault_uuid":"u","vault_name":"v","current_version":1,"versions":[{"version":1,"key_b64":"` + b64(key(1)) + `","key_check":"c","needed":true,"extra":1}]}}`
	if r := h.send(nested)[0]; r.OK || r.Error.Code != CodeBadRequest || !strings.Contains(r.Error.Message, "versions.extra") {
		t.Fatalf("nested unknown field: %s", r.raw)
	}
	if h.mem.Writes != 0 {
		t.Fatal("an invalid request wrote")
	}
}

// --- items.list ---

func TestItemsListReturnsMetadataNeverSecrets(t *testing.T) {
	h, vaultID := connected(t)
	h.ok("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), nil)
	other := v(1, 7)
	other.KeyCheck = kcFor("43", 1, 7)
	p := upsertParams(vaultID, 1, other)
	p["node_id"], p["vault_uuid"] = "node-2", "43"
	h.ok("item.upsert", p, nil)
	h.mem.Put(store.Item{VaultID: vaultID, Category: store.CategoryAPICredentials, Title: "unrelated",
		Fields: []store.Field{{ID: "credential", Type: store.FieldConcealed, Value: b64(key(5))}}})

	r := h.ok("items.list", map[string]string{"vault_id": vaultID}, nil)
	for _, secret := range []string{b64(key(1)), b64(key(2)), b64(key(5)), b64(key(7)), "key_b64", "credential"} {
		if strings.Contains(r.raw, secret) {
			t.Fatalf("items.list output contains %q: %s", secret, r.raw)
		}
	}
	var res ItemsListResult
	if err := json.Unmarshal(r.Result, &res); err != nil {
		t.Fatal(err)
	}
	if len(res.Items) != 2 {
		t.Fatalf("want 2 backup items, got %d", len(res.Items))
	}
	m := res.Items[0]
	if m.NodeID != "node-1" || m.VaultUUID != testVault || m.CurrentVersion != 2 || m.KeyCheck != kc(2, 2) ||
		m.NodeName != "Home Lab" || m.VaultName != "Photos" || m.UpdatedAt == "" || m.BackedUpAt == "" || len(m.Issues) != 0 ||
		fmt.Sprint(m.Versions) != fmt.Sprint([]VersionMeta{{Version: 2, KeyCheck: kc(2, 2), State: StateCurrent}, {Version: 1, KeyCheck: kc(1, 1), State: StateNeeded}}) {
		t.Fatalf("meta %+v", m)
	}
}

func TestItemsListReportsDamagedItems(t *testing.T) {
	h, vaultID := connected(t)
	var res UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 1, v(1, 1)), &res)
	it := h.item(vaultID, res.ItemID)
	for i, f := range it.Fields {
		if f.ID == FieldCredential {
			it.Fields[i].Value = b64(key(9))
		}
	}
	h.mem.Put(it)
	var list ItemsListResult
	h.ok("items.list", map[string]string{"vault_id": vaultID}, &list)
	if len(list.Items) != 1 || len(list.Items[0].Issues) != 1 || !strings.Contains(list.Items[0].Issues[0], "credential differs") {
		t.Fatalf("issues %+v", list.Items)
	}
	if strings.Contains(fmt.Sprint(list), b64(key(9))) {
		t.Fatal("issue text leaks a key")
	}
}

// --- item.reveal ---

func TestRevealReturnsRequestedVersions(t *testing.T) {
	h, vaultID := connected(t)
	var up UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), &up)

	type revealed struct {
		ItemID         string `json:"item_id"`
		NodeID         string `json:"node_id"`
		VaultUUID      string `json:"vault_uuid"`
		CurrentVersion int    `json:"current_version"`
		Versions       []struct {
			Version  int    `json:"version"`
			KeyCheck string `json:"key_check"`
			State    string `json:"state"`
			Key      []byte `json:"key_b64"`
		} `json:"versions"`
	}
	var all revealed
	h.ok("item.reveal", map[string]any{"vault_id": vaultID, "item_id": up.ItemID}, &all)
	if all.ItemID != up.ItemID || all.NodeID != "node-1" || all.VaultUUID != testVault || all.CurrentVersion != 2 || len(all.Versions) != 2 ||
		all.Versions[0].Version != 2 || !bytes.Equal(all.Versions[0].Key, key(2)) || all.Versions[0].KeyCheck != kc(2, 2) ||
		all.Versions[1].Version != 1 || !bytes.Equal(all.Versions[1].Key, key(1)) {
		t.Fatalf("reveal all: %+v", all)
	}
	var one revealed
	h.ok("item.reveal", map[string]any{"vault_id": vaultID, "item_id": up.ItemID, "versions": []int{1}}, &one)
	if len(one.Versions) != 1 || one.Versions[0].Version != 1 || !bytes.Equal(one.Versions[0].Key, key(1)) {
		t.Fatalf("reveal one: %+v", one)
	}
	h.fails("item.reveal", map[string]any{"vault_id": vaultID, "item_id": up.ItemID, "versions": []int{7}}, CodeNotFound)
	h.fails("item.reveal", map[string]any{"vault_id": vaultID, "item_id": "nope"}, CodeNotFound)
}

// --- protocol ---

func TestMalformedRequests(t *testing.T) {
	h := newHarness(t)
	res := h.send(
		`not json`,
		`{"op":"account.check","params":{"account":"x"}}`,
		`{"id":{"a":1},"op":"account.check"}`,
		`{"id":7,"op":"nope"}`,
		`{"id":8,"op":"account.check","params":[]}`,
		`{"id":9,"op":"account.check","params":{"account":"x"},"extra":true}`,
		`["id",1]`,
		``,
		`{"id":"req-10","op":"account.check","params":{"account":"Cooper"}}`,
	)
	want := []struct {
		id, code string
	}{{"null", CodeBadRequest}, {"null", CodeBadRequest}, {"null", CodeBadRequest}, {"7", CodeUnknownOp},
		{"8", CodeBadRequest}, {"null", CodeBadRequest}, {"null", CodeBadRequest}, {`"req-10"`, ""}}
	if len(res) != len(want) {
		t.Fatalf("want %d responses, got %d", len(want), len(res))
	}
	for i, w := range want {
		if string(res[i].ID) != w.id {
			t.Errorf("response %d: id %s, want %s", i, res[i].ID, w.id)
		}
		if w.code == "" {
			if !res[i].OK {
				t.Errorf("response %d: want ok, got %s", i, res[i].raw)
			}
		} else if res[i].OK || res[i].Error.Code != w.code {
			t.Errorf("response %d: want %s, got %s", i, w.code, res[i].raw)
		}
	}
}

func TestOversizeLineIsRejectedAndTheStreamRecovers(t *testing.T) {
	h := newHarness(t)
	h.server.MaxLine = 1024
	huge := `{"id":1,"op":"account.check","params":{"account":"` + strings.Repeat("a", 200_000) + `"}}`
	res := h.send(huge, `{"id":2,"op":"account.check","params":{"account":"Cooper"}}`)
	if len(res) != 2 {
		t.Fatalf("want 2 responses, got %d", len(res))
	}
	if string(res[0].ID) != "null" || res[0].Error == nil || res[0].Error.Code != CodeLineTooLong {
		t.Fatalf("oversize: %s", res[0].raw)
	}
	if string(res[1].ID) != "2" || !res[1].OK {
		t.Fatalf("after oversize: %s", res[1].raw)
	}
}

func TestDiagnosticsCarryNoSecrets(t *testing.T) {
	h, vaultID := connected(t)
	var up UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), &up)
	h.fails("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 9)), CodeVersionConflict)
	h.ok("item.reveal", map[string]any{"vault_id": vaultID, "item_id": up.ItemID}, nil)
	h.send(`{"id":5,"op":"` + b64(key(3)) + `"}`)
	log := h.log.String()
	for _, k := range []byte{1, 2, 3, 9} {
		if strings.Contains(log, b64(key(k))) {
			t.Fatalf("stderr contains key %d:\n%s", k, log)
		}
	}
	if !strings.Contains(log, "op=item.upsert ok") || !strings.Contains(log, "error=version_conflict") {
		t.Fatalf("log lacks diagnostics:\n%s", log)
	}
}

func TestServeStopsAtEOF(t *testing.T) {
	h := newHarness(t)
	var out bytes.Buffer
	if err := h.server.Serve(context.Background(), strings.NewReader(""), &out); err != nil || out.Len() != 0 {
		t.Fatalf("err %v out %q", err, out.String())
	}
	// A last line without a newline is still answered.
	if err := h.server.Serve(context.Background(), strings.NewReader(`{"id":1,"op":"nope"}`), &out); err != nil || !strings.Contains(out.String(), "unknown_op") {
		t.Fatalf("err %v out %q", err, out.String())
	}
}

// --- units ---

type oneByteReader struct{ r io.Reader }

func (o oneByteReader) Read(p []byte) (int, error) { return o.r.Read(p[:1]) }

func TestLineReaderSplitsAcrossReads(t *testing.T) {
	lr := &lineReader{r: oneByteReader{strings.NewReader("ab\r\n\ncd\nlast")}, chunk: make([]byte, 3), max: 10}
	var got []string
	for {
		line, tooLong, err := lr.next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil || tooLong {
			t.Fatalf("err %v tooLong %v", err, tooLong)
		}
		got = append(got, string(line.bytes()))
	}
	if fmt.Sprintf("%q", got) != `["ab\r" "" "cd" "last"]` {
		t.Fatalf("%q", got)
	}
}

func TestSecureBufWipesOnGrowth(t *testing.T) {
	buf := newSecureBuf(4)
	buf.writeString("abcd")
	old := buf.b[:cap(buf.b)]
	buf.writeBase64([]byte{1, 2, 3})
	if string(old) != "\x00\x00\x00\x00" {
		t.Fatalf("old backing array not wiped: %q", old)
	}
	if string(buf.bytes()) != `abcd"AQID"` {
		t.Fatalf("%q", buf.bytes())
	}
	all := buf.b[:cap(buf.b)]
	buf.wipe()
	for _, c := range all {
		if c != 0 {
			t.Fatal("wipe left bytes")
		}
	}
}

func TestClassify(t *testing.T) {
	cases := map[string]string{
		store.ScenarioMessages["integration_disabled"]:                                    CodeIntegrationDisabled,
		store.ScenarioMessages["app_not_running"]:                                         CodeAppNotRunning,
		"1Password desktop application not found":                                         CodeAppNotInstalled,
		"failed to load send_message":                                                     CodeLibraryBlocked,
		"WithDesktopAppIntegration requires CGO to cross-compile. See README CGO section": CodeUnsupportedBuild,
		"rate limit exceeded":                                                             CodeRateLimited,
		"incorrect item version":                                                          CodeConcurrentModification,
		"user declined the request":                                                       CodeDenied,
		"you don't have the right permissions to execute this request":                    CodeDenied,
		"vault is locked":                                                                 CodeLocked,
		"app unlocked, server error":                                                      CodeOnePassword,
		"account foo not found":                                                           CodeAccountNotFound,
		"item not found":                                                                  CodeNotFound,
		"server error":                                                                    CodeOnePassword,
	}
	for msg, want := range cases {
		if got := classify(errors.New(msg)); got != want {
			t.Errorf("classify(%q) = %s, want %s", msg, got, want)
		}
	}
}

func TestNodeSlug(t *testing.T) {
	for in, want := range map[string]string{"Home Lab": "home-lab", "  vh--storage!! ": "vh-storage", "Ünïcode": "n-code", "***": "node"} {
		if got := nodeSlug(in); got != want {
			t.Errorf("nodeSlug(%q) = %q, want %q", in, got, want)
		}
	}
}

// --- self-test ---

func TestSelfTestIsReadOnly(t *testing.T) {
	mem := store.NewMemory()
	var out bytes.Buffer
	if code := SelfTest(context.Background(), mem, "Cooper", "Vaulthalla", &out); code != 0 {
		t.Fatalf("exit %d: %s", code, out.String())
	}
	if vaults, _ := mem.ListVaults(context.Background()); len(vaults) != 0 || mem.Writes != 0 {
		t.Fatal("self-test wrote")
	}
	if !strings.Contains(out.String(), "no vault titled") {
		t.Fatal(out.String())
	}

	// With a backup present: metadata only.
	h, vaultID := connected(t)
	h.ok("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), nil)
	writes := h.mem.Writes
	out.Reset()
	if code := SelfTest(context.Background(), h.mem, "Cooper", "Vaulthalla", &out); code != 0 {
		t.Fatalf("exit %d: %s", code, out.String())
	}
	if h.mem.Writes != writes || strings.Contains(out.String(), b64(key(1))) || !strings.Contains(out.String(), "versions=[v2(current) v1(needed)]") {
		t.Fatalf("self-test output:\n%s", out.String())
	}

	out.Reset()
	if code := SelfTest(context.Background(), mem, "fake:integration_disabled", "Vaulthalla", &out); code != 1 ||
		!strings.Contains(out.String(), "[integration_disabled]") || !strings.Contains(out.String(), "Integrate with other apps") {
		t.Fatalf("exit %d: %s", code, out.String())
	}
}
