package backup

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/valkyrianlabs/vaulthalla-desktop/helpers/vaulthalla-1password/internal/store"
)

// Results. None of these carries key material except RevealResult, which encodes itself (jsonAppender).

type AccountResult struct {
	Account    string `json:"account"`
	Connected  bool   `json:"connected"`
	VaultCount int    `json:"vault_count"`
}

type VaultResult struct {
	VaultID string `json:"vault_id"`
	Title   string `json:"title"`
	Created bool   `json:"created"`
}

type VersionMeta struct {
	Version  int    `json:"version"`
	KeyCheck string `json:"key_check"`
	State    string `json:"state,omitempty"`
	// The node's attestation (non-secret), when the version has one.
	Attestation *Attestation `json:"attestation,omitempty"`
}

// ItemMeta is what items.list says about an item: identifiers, versions and key checks. No key values.
type ItemMeta struct {
	ItemID         string        `json:"item_id"`
	VaultID        string        `json:"vault_id"`
	Title          string        `json:"title"`
	NodeID         string        `json:"node_id"`
	NodeName       string        `json:"node_name"`
	VaultUUID      string        `json:"vault_uuid"`
	VaultName      string        `json:"vault_name"`
	CurrentVersion int           `json:"current_version"`
	KeyCheck       string        `json:"key_check"`
	Versions       []VersionMeta `json:"versions"`
	UpdatedAt      string        `json:"updated_at,omitempty"`
	BackedUpAt     string        `json:"backed_up_at,omitempty"`
	Issues         []string      `json:"issues"`
}

type ItemsListResult struct {
	Items []ItemMeta `json:"items"`
}

type UpsertResult struct {
	ItemID         string        `json:"item_id"`
	VaultID        string        `json:"vault_id"`
	Created        bool          `json:"created"`
	Written        bool          `json:"written"`
	CurrentVersion int           `json:"current_version"`
	KeyCheck       string        `json:"key_check"`
	StoredVersions []VersionMeta `json:"stored_versions"`
	UpdatedAt      string        `json:"updated_at,omitempty"`
}

func timeString(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

func (p parsedItem) meta() ItemMeta {
	m := ItemMeta{ItemID: p.Item.ID, VaultID: p.Item.VaultID, Title: p.Item.Title, NodeID: p.NodeID,
		NodeName: p.NodeName, VaultUUID: p.VaultUUID, VaultName: p.VaultName, CurrentVersion: p.CurrentVersion,
		KeyCheck: p.KeyCheck, UpdatedAt: timeString(p.Item.UpdatedAt), BackedUpAt: p.BackedUpAt,
		Issues: append([]string{}, p.Issues...), Versions: []VersionMeta{}}
	for _, v := range p.sortedVersions() {
		sv := p.Versions[v]
		m.Versions = append(m.Versions, VersionMeta{Version: v, KeyCheck: sv.KeyCheck, State: sv.State,
			Attestation: sv.Attestation})
	}
	return m
}

// decodeParams decodes strictly: unknown fields are a bad request, so a mismatch between app and helper shows up
// instead of being ignored.
func decodeParams(raw []byte, into any) *Error {
	if len(raw) == 0 || string(raw) == "null" {
		raw = []byte("{}")
	}
	if err := strictUnmarshal(raw, into); err != nil {
		return newError(CodeBadRequest, "invalid params: "+sanitizeJSONError(err))
	}
	return nil
}

// sanitizeJSONError keeps encoding/json's description of what was wrong but never echoes input values.
func sanitizeJSONError(err error) string {
	switch e := err.(type) {
	case *json.UnmarshalTypeError:
		if e.Field != "" {
			return fmt.Sprintf("field %q has the wrong type", e.Field)
		}
		return "params must be an object"
	case *json.SyntaxError:
		return "malformed JSON"
	case unknownFieldError:
		return "unknown field " + strconv.Quote(e.name)
	}
	if strings.Contains(err.Error(), "illegal base64") {
		return "key_b64 isn't valid base64"
	}
	return "malformed params"
}

// --- account.check ---

type accountParams struct {
	Account string `json:"account"`
}

func (s *Server) accountCheck(ctx context.Context, raw []byte, _ *Redactor) (any, error) {
	var p accountParams
	if e := decodeParams(raw, &p); e != nil {
		return nil, e
	}
	if e := validText("account", p.Account, true); e != nil {
		return nil, e
	}
	// The SDK binds its IPC library to the first account name it sees, so a process serves one account.
	if s.boundAccount != "" && s.boundAccount != p.Account {
		return nil, newError(CodeAccountSwitch, "this helper process is bound to another 1Password account")
	}
	s.boundAccount = p.Account
	if s.backend == nil {
		b, err := s.Connector.Connect(ctx, p.Account)
		if err != nil {
			return nil, err
		}
		s.backend = b
	}
	vaults, err := s.backend.ListVaults(ctx)
	if err != nil {
		if code := classify(err); code != CodeNotFound && code != CodeOnePassword {
			s.backend = nil // reconnect next time (locked, denied, app gone)
		}
		return nil, err
	}
	return AccountResult{Account: p.Account, Connected: true, VaultCount: len(vaults)}, nil
}

func (s *Server) session() (store.Backend, *Error) {
	if s.backend == nil {
		e := newError(CodeNoSession, "no 1Password session")
		e.Hint = "Send account.check first."
		return nil, e
	}
	return s.backend, nil
}

// --- vault.ensure ---

type vaultParams struct {
	Title string `json:"title"`
}

func (s *Server) vaultEnsure(ctx context.Context, raw []byte, _ *Redactor) (any, error) {
	var p vaultParams
	if e := decodeParams(raw, &p); e != nil {
		return nil, e
	}
	if e := validText("title", p.Title, true); e != nil {
		return nil, e
	}
	b, e := s.session()
	if e != nil {
		return nil, e
	}
	vaults, err := b.ListVaults(ctx)
	if err != nil {
		return nil, err
	}
	var found []store.Vault
	for _, v := range vaults {
		if v.Title == p.Title {
			found = append(found, v)
		}
	}
	switch len(found) {
	case 0:
		v, err := b.CreateVault(ctx, p.Title)
		if err != nil {
			return nil, err
		}
		return VaultResult{VaultID: v.ID, Title: v.Title, Created: true}, nil
	case 1:
		return VaultResult{VaultID: found[0].ID, Title: found[0].Title}, nil
	}
	ids := make([]string, 0, len(found))
	for _, v := range found {
		ids = append(ids, v.ID)
	}
	return nil, newError(CodeAmbiguousVault,
		fmt.Sprintf("%d vaults are titled %q (%s); choose one", len(found), p.Title, strings.Join(ids, ", ")))
}

// --- finding items ---

// backups reads every Vaulthalla backup item in a vault. Overviews carry no fields, so each API Credential item
// is read in full; the vault is dedicated to Vaulthalla, so that's a handful of items.
func backups(ctx context.Context, b store.Backend, vaultID string) ([]parsedItem, error) {
	overviews, err := b.ListItems(ctx, vaultID)
	if err != nil {
		return nil, err
	}
	var out []parsedItem
	for _, o := range overviews {
		if o.Category != store.CategoryAPICredentials {
			continue
		}
		it, err := b.GetItem(ctx, vaultID, o.ID)
		if err != nil {
			return nil, err
		}
		if p, ok := parseItem(it); ok {
			out = append(out, p)
		}
	}
	return out, nil
}

// findBackup returns the item for (node id, vault id), matched on those fields only, never on the title.
func findBackup(ctx context.Context, b store.Backend, vaultID, nodeID, vaultUUID string) (*parsedItem, error) {
	all, err := backups(ctx, b, vaultID)
	if err != nil {
		return nil, err
	}
	var match []parsedItem
	for _, p := range all {
		if p.NodeID == nodeID && p.VaultUUID == vaultUUID {
			match = append(match, p)
		}
	}
	switch len(match) {
	case 0:
		return nil, nil
	case 1:
		return &match[0], nil
	}
	ids := make([]string, 0, len(match))
	for _, p := range match {
		ids = append(ids, p.Item.ID)
	}
	return nil, newError(CodeDuplicateItem,
		fmt.Sprintf("%d items back up this vault (%s); merge or archive the extra ones in 1Password", len(match), strings.Join(ids, ", ")))
}

// --- items.list ---

type listParams struct {
	VaultID string `json:"vault_id"`
}

func (s *Server) itemsList(ctx context.Context, raw []byte, _ *Redactor) (any, error) {
	var p listParams
	if e := decodeParams(raw, &p); e != nil {
		return nil, e
	}
	if e := validText("vault_id", p.VaultID, true); e != nil {
		return nil, e
	}
	b, e := s.session()
	if e != nil {
		return nil, e
	}
	all, err := backups(ctx, b, p.VaultID)
	if err != nil {
		return nil, err
	}
	res := ItemsListResult{Items: make([]ItemMeta, 0, len(all))}
	for _, it := range all {
		res.Items = append(res.Items, it.meta())
	}
	slices.SortFunc(res.Items, func(a, b ItemMeta) int {
		return strings.Compare(a.NodeID+"\x00"+a.VaultUUID, b.NodeID+"\x00"+b.VaultUUID)
	})
	return res, nil
}

// --- item.upsert ---

func (s *Server) itemUpsert(ctx context.Context, raw []byte, r *Redactor) (any, error) {
	var p UpsertParams
	defer p.wipe()
	if e := decodeParams(raw, &p); e != nil {
		return nil, e
	}
	if e := p.validate(); e != nil {
		return nil, e
	}
	b, e := s.session()
	if e != nil {
		return nil, e
	}
	existing, err := findBackup(ctx, b, p.VaultID, p.NodeID, p.VaultUUID)
	if err != nil {
		return nil, err
	}
	desired, changed, merr := merge(existing, &p, s.now(), r)
	if merr != nil {
		return nil, merr
	}

	var written store.Item
	switch {
	case existing == nil:
		written, err = b.CreateItem(ctx, desired)
	case changed:
		written, err = b.PutItem(ctx, desired)
	default:
		written = existing.Item
	}
	if err != nil {
		return nil, err
	}

	// Read back what 1Password holds now and verify it, so the app confirms the export to the daemon only on what
	// was actually stored.
	readBack, err := b.GetItem(ctx, p.VaultID, written.ID)
	if err != nil {
		return nil, err
	}
	stored, ok := parseItem(readBack)
	if !ok {
		return nil, newError(CodeVerifyFailed, "the item read back from 1Password has no Vaulthalla identifiers")
	}
	for _, v := range stored.Versions {
		r.add(v.Value)
	}
	if e := verify(stored, &p); e != nil {
		return nil, e
	}
	res := UpsertResult{ItemID: stored.Item.ID, VaultID: stored.Item.VaultID, Created: existing == nil,
		Written: existing == nil || changed, CurrentVersion: stored.CurrentVersion, KeyCheck: stored.KeyCheck,
		StoredVersions: stored.meta().Versions, UpdatedAt: timeString(stored.Item.UpdatedAt)}
	return res, nil
}

func verify(stored parsedItem, p *UpsertParams) *Error {
	fail := func(what string) *Error {
		return newError(CodeVerifyFailed, "1Password's copy doesn't match what was written: "+what)
	}
	if stored.NodeID != p.NodeID || stored.VaultUUID != p.VaultUUID {
		return fail("identifiers")
	}
	for _, v := range p.Versions {
		sv, ok := stored.Versions[v.Version]
		if !ok {
			return fail(versionField(v.Version) + " is missing")
		}
		if !sameKey(sv.Value, v.Key) || sv.KeyCheck != v.KeyCheck {
			return fail(versionField(v.Version) + " differs")
		}
		if v.Attestation != nil && !sv.Attestation.equal(v.Attestation) {
			return fail(versionField(v.Version) + "'s attestation differs")
		}
	}
	// Every stored version, including ones this request didn't carry, is checked against its key check again, so
	// the app never confirms a backup whose item holds a key that isn't what its check says.
	for _, n := range stored.sortedVersions() {
		sv := stored.Versions[n]
		if !storedKeyCheckMatches(sv.Value, p.VaultUUID, n, sv.KeyCheck) {
			return fail(versionField(n) + " doesn't match its key check")
		}
	}
	current, _ := p.incoming(p.CurrentVersion)
	if stored.CurrentVersion != p.CurrentVersion || stored.KeyCheck != current.KeyCheck || !sameKey(stored.Credential, current.Key) {
		return fail("current version")
	}
	return nil
}

// --- item.reveal ---

type revealParams struct {
	VaultID  string `json:"vault_id"`
	ItemID   string `json:"item_id"`
	Versions []int  `json:"versions"`
}

// RevealResult carries key material; it encodes itself into a secureBuf and wipes its keys afterwards.
type RevealResult struct {
	ItemID         string
	VaultID        string
	NodeID         string
	VaultUUID      string
	CurrentVersion int
	Versions       []RevealedVersion
}

type RevealedVersion struct {
	Version     int
	KeyCheck    string
	State       string
	Attestation *Attestation
	Key         []byte
}

func (rr *RevealResult) appendJSON(buf *secureBuf) error {
	head := struct {
		ItemID         string `json:"item_id"`
		VaultID        string `json:"vault_id"`
		NodeID         string `json:"node_id"`
		VaultUUID      string `json:"vault_uuid"`
		CurrentVersion int    `json:"current_version"`
	}{rr.ItemID, rr.VaultID, rr.NodeID, rr.VaultUUID, rr.CurrentVersion}
	if err := buf.writeJSON(head); err != nil {
		return err
	}
	buf.b = buf.b[:len(buf.b)-1] // reopen the object
	buf.writeString(`,"versions":[`)
	for i, v := range rr.Versions {
		if i > 0 {
			buf.writeByte(',')
		}
		buf.writeString(`{"version":` + strconv.Itoa(v.Version) + `,"key_check":`)
		if err := buf.writeJSON(v.KeyCheck); err != nil {
			return err
		}
		buf.writeString(`,"state":`)
		if err := buf.writeJSON(v.State); err != nil {
			return err
		}
		if v.Attestation != nil {
			buf.writeString(`,"attestation":`)
			if err := buf.writeJSON(v.Attestation); err != nil {
				return err
			}
		}
		buf.writeString(`,"key_b64":`)
		buf.writeBase64(v.Key)
		buf.writeByte('}')
	}
	buf.writeString("]}")
	return nil
}

func (rr *RevealResult) wipe() {
	for i := range rr.Versions {
		wipe(rr.Versions[i].Key)
	}
}

func (s *Server) itemReveal(ctx context.Context, raw []byte, r *Redactor) (any, error) {
	var p revealParams
	if e := decodeParams(raw, &p); e != nil {
		return nil, e
	}
	if e := validText("vault_id", p.VaultID, true); e != nil {
		return nil, e
	}
	if e := validText("item_id", p.ItemID, true); e != nil {
		return nil, e
	}
	b, e := s.session()
	if e != nil {
		return nil, e
	}
	it, err := b.GetItem(ctx, p.VaultID, p.ItemID)
	if err != nil {
		return nil, err
	}
	parsed, ok := parseItem(it)
	if !ok {
		return nil, newError(CodeNotFound, "that item isn't a Vaulthalla key backup")
	}
	versions := p.Versions
	if len(versions) == 0 {
		versions = parsed.sortedVersions()
	}
	res := &RevealResult{ItemID: it.ID, VaultID: it.VaultID, NodeID: parsed.NodeID, VaultUUID: parsed.VaultUUID,
		CurrentVersion: parsed.CurrentVersion}
	for _, v := range versions {
		sv, ok := parsed.Versions[v]
		if !ok {
			res.wipe()
			return nil, newError(CodeNotFound, fmt.Sprintf("the item has no key version %d", v))
		}
		r.add(sv.Value)
		key, err := base64.StdEncoding.DecodeString(sv.Value)
		if err != nil || len(key) == 0 {
			wipe(key)
			res.wipe()
			return nil, newError(CodeVerifyFailed, fmt.Sprintf("stored version %d isn't a base64 key", v))
		}
		// A restore must never hand the daemon a key that isn't what its check says (a hand edit, damage).
		if !keyCheckMatches(key, parsed.VaultUUID, v, sv.KeyCheck) {
			wipe(key)
			res.wipe()
			return nil, newError(CodeKeyCheckMismatch, fmt.Sprintf("stored version %d doesn't match its key check", v))
		}
		res.Versions = append(res.Versions, RevealedVersion{Version: v, KeyCheck: sv.KeyCheck, State: sv.State,
			Attestation: sv.Attestation, Key: key})
	}
	return res, nil
}
