package backup

import (
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/valkyrianlabs/vaulthalla-desktop/helpers/vaulthalla-1password/internal/store"
)

// The item layout (docs/architecture.md §6, decision D6). One API Credential item per (node, Vaulthalla vault):
//
//	title       Vaulthalla · <vault> · <node>
//	credential  the current key (base64), built-in concealed field
//	section "Vaulthalla"     node id, node name, vault id, vault name, key version, key check, backed up, format
//	section "Key versions"   vN (concealed, base64 key), vN key check, vN state — one triple per version
//	tags        vaulthalla, vaulthalla/<node-slug>
//	notes       restore instructions (written when the item is created; the user may edit them)
//
// The item is found by the node id + vault id fields, never by title. Field ids are the stable identifiers;
// titles are for people.
const (
	SectionMeta     = "vaulthalla"
	SectionVersions = "key_versions"

	FieldCredential = "credential"
	FieldNodeID     = "vh_node_id"
	FieldNodeName   = "vh_node_name"
	FieldVaultUUID  = "vh_vault_id"
	FieldVaultName  = "vh_vault_name"
	FieldKeyVersion = "vh_key_version"
	FieldKeyCheck   = "vh_key_check"
	FieldBackedUpAt = "vh_backed_up_at"
	FieldFormat     = "vh_format"

	Format  = "vaulthalla-key-backup/1"
	TagRoot = "vaulthalla"

	StateCurrent = "current" // the daemon's current key
	StateNeeded  = "needed"  // an older key the daemon still needs to decrypt files
	StateRetired = "retired" // no longer listed by the daemon; kept, never deleted by the helper
)

var versionFieldID = regexp.MustCompile(`^v([1-9][0-9]{0,9})$`)

func versionField(v int) string { return "v" + strconv.Itoa(v) }
func checkField(v int) string   { return versionField(v) + "_check" }
func stateField(v int) string   { return versionField(v) + "_state" }

// Attestation fields (non-secret metadata next to each version's key): the node's Ed25519 attestation of the version
// (the id of the node's signing key + a signature over "vh-key-attest-v1" ‖ node_id ‖ vault_id ‖ version ‖
// key_check). The helper never verifies them (the daemon does on import); it stores and returns them unchanged.
func attestKeyField(v int) string { return versionField(v) + "_attest_key_id" }
func attestSigField(v int) string { return versionField(v) + "_attest_sig" }

func itemTitle(vaultName, nodeName string) string {
	return "Vaulthalla · " + vaultName + " · " + nodeName
}

// nodeSlug turns a node name into a tag component: lowercase letters, digits and dashes.
func nodeSlug(name string) string {
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(name) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			dash = false
		} else if b.Len() > 0 && !dash {
			b.WriteByte('-')
			dash = true
		}
	}
	slug := strings.TrimSuffix(b.String(), "-")
	if slug == "" {
		return "node"
	}
	return slug
}

func restoreNotes(nodeName, vaultName string) string {
	return "Vault key backup written by Vaulthalla Desktop for vault “" + vaultName + "” on node “" + nodeName + "”.\n\n" +
		"Each field under “Key versions” is one version of the vault's key (base64). Files written under an older key " +
		"need that version to decrypt, so keep every version.\n\n" +
		"To restore: in Vaulthalla Desktop, open the vault's key backup and choose Restore (or Export to save the " +
		"keys in `vh vault keys export` format and import them with `vh vault keys import`).\n\n" +
		"Don't edit the key fields by hand; Vaulthalla Desktop refuses to overwrite a stored version."
}

// storedVersion is one version as found in an item.
type storedVersion struct {
	Version  int
	Value    string // base64 key; never leaves the helper except through item.reveal
	KeyCheck string
	State    string
	// Attestation metadata; nil when the version was backed up without one (it can only be salvaged).
	Attestation *Attestation
}

// Attestation is the daemon's `{key_id, signature}`: key_id is the id of the node's signing key (an unsigned integer,
// stored as decimal text), signature the base64 Ed25519 signature. Opaque to the helper otherwise.
type Attestation struct {
	KeyID     uint32 `json:"key_id"`
	Signature string `json:"signature"`
}

// validKeyID: the daemon's attestation signing key ids are a SERIAL (key_attestation_keys.id), 1..2^31-1. The
// daemon reads any other value as a malformed attestation, never as another key's id.
func validKeyID(id uint64) bool { return id >= 1 && id <= maxAttestationKeyID }

func (a *Attestation) equal(b *Attestation) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

// parsedItem is an item read as a Vaulthalla backup.
type parsedItem struct {
	Item           store.Item
	NodeID         string
	NodeName       string
	VaultUUID      string
	VaultName      string
	CurrentVersion int
	KeyCheck       string
	BackedUpAt     string
	Credential     string
	Versions       map[int]storedVersion
	Issues         []string
}

// parseItem reads an item's Vaulthalla fields. ok is false when the item isn't a Vaulthalla backup (no node id or
// vault id field).
func parseItem(it store.Item) (parsedItem, bool) {
	p := parsedItem{Item: it, Versions: map[int]storedVersion{}}
	text := func(id string) string {
		f, _ := it.Field(SectionMeta, id)
		return f.Value
	}
	p.NodeID, p.VaultUUID = text(FieldNodeID), text(FieldVaultUUID)
	if p.NodeID == "" || p.VaultUUID == "" {
		return p, false
	}
	p.NodeName, p.VaultName = text(FieldNodeName), text(FieldVaultName)
	p.KeyCheck, p.BackedUpAt = text(FieldKeyCheck), text(FieldBackedUpAt)
	if v := text(FieldKeyVersion); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			p.Issues = append(p.Issues, "the key version field isn't a version number")
		} else {
			p.CurrentVersion = n
		}
	}
	if f, ok := it.Field("", FieldCredential); ok {
		p.Credential = f.Value
	}
	for _, f := range it.Fields {
		if f.SectionID != SectionVersions {
			continue
		}
		m := versionFieldID.FindStringSubmatch(f.ID)
		if m == nil {
			continue
		}
		v, _ := strconv.Atoi(m[1])
		check, _ := it.Field(SectionVersions, checkField(v))
		state, _ := it.Field(SectionVersions, stateField(v))
		sv := storedVersion{Version: v, Value: f.Value, KeyCheck: check.Value, State: state.Value}
		keyID, _ := it.Field(SectionVersions, attestKeyField(v))
		sig, _ := it.Field(SectionVersions, attestSigField(v))
		// A hand-edited attestation (no number, a key id outside the daemon's 1..2^31-1, no signature) is no
		// attestation: the version can still be salvaged, and the node's can be stored again. The key itself is
		// unaffected, so this is not an issue.
		if id, err := strconv.ParseUint(keyID.Value, 10, 32); err == nil && validKeyID(id) && sig.Value != "" {
			sv.Attestation = &Attestation{KeyID: uint32(id), Signature: sig.Value}
		}
		p.Versions[v] = sv
	}
	vaultNumber := isVaultNumber(p.VaultUUID)
	if !vaultNumber {
		p.Issues = append(p.Issues, "the vault id isn't a Vaulthalla vault number, so its key checks can't be verified")
	}
	for _, v := range p.sortedVersions() {
		sv := p.Versions[v]
		switch {
		case !validBase64Key(sv.Value):
			p.Issues = append(p.Issues, fmt.Sprintf("%s isn't a base64 key", versionField(v)))
		case sv.KeyCheck == "":
			p.Issues = append(p.Issues, fmt.Sprintf("%s has no key check", versionField(v)))
		case vaultNumber && !storedKeyCheckMatches(sv.Value, p.VaultUUID, v, sv.KeyCheck):
			// Recomputed from the stored key: a hand edit or damage, never trusted for a restore.
			p.Issues = append(p.Issues, fmt.Sprintf("%s doesn't match its key check", versionField(v)))
		}
	}
	if p.CurrentVersion != 0 {
		cur, ok := p.Versions[p.CurrentVersion]
		switch {
		case !ok:
			p.Issues = append(p.Issues, fmt.Sprintf("the current version %s is missing", versionField(p.CurrentVersion)))
		case !sameKeyText(cur.Value, p.Credential):
			p.Issues = append(p.Issues, fmt.Sprintf("credential differs from %s", versionField(p.CurrentVersion)))
		case cur.KeyCheck != p.KeyCheck:
			p.Issues = append(p.Issues, fmt.Sprintf("the key check differs from %s's", versionField(p.CurrentVersion)))
		}
	}
	return p, true
}

func (p parsedItem) sortedVersions() []int {
	out := make([]int, 0, len(p.Versions))
	for v := range p.Versions {
		out = append(out, v)
	}
	sort.Sort(sort.Reverse(sort.IntSlice(out)))
	return out
}

func validBase64Key(s string) bool {
	b, err := base64.StdEncoding.DecodeString(s)
	defer wipe(b)
	return err == nil && len(b) > 0
}

// sameKeyText compares two base64 key texts by their decoded bytes, in constant time.
func sameKeyText(a, b string) bool {
	ab, errA := base64.StdEncoding.DecodeString(a)
	bb, errB := base64.StdEncoding.DecodeString(b)
	defer wipe(ab)
	defer wipe(bb)
	return errA == nil && errB == nil && len(ab) > 0 && subtle.ConstantTimeCompare(ab, bb) == 1
}

// sameKey compares a stored base64 key text with incoming key bytes, in constant time.
func sameKey(stored string, key []byte) bool {
	b, err := base64.StdEncoding.DecodeString(stored)
	defer wipe(b)
	return err == nil && subtle.ConstantTimeCompare(b, key) == 1
}

// IncomingVersion is one key version sent by the app. Key is decoded from base64 by encoding/json into a fresh
// slice the handler wipes.
type IncomingVersion struct {
	Version  int    `json:"version"`
	Key      []byte `json:"key_b64"`
	KeyCheck string `json:"key_check"`
	Needed   bool   `json:"needed"`
	// Optional: the node's attestation of the version, stored as given.
	Attestation *Attestation `json:"attestation,omitempty"`
}

type UpsertParams struct {
	VaultID        string            `json:"vault_id"`
	NodeID         string            `json:"node_id"`
	NodeName       string            `json:"node_name"`
	VaultUUID      string            `json:"vault_uuid"`
	VaultName      string            `json:"vault_name"`
	Versions       []IncomingVersion `json:"versions"`
	CurrentVersion int               `json:"current_version"`
}

func (p *UpsertParams) wipe() {
	for i := range p.Versions {
		wipe(p.Versions[i].Key)
	}
}

const (
	maxVersions   = 1000
	maxTextLength = 512
)

func validText(name, s string, required bool) *Error {
	if s == "" {
		if required {
			return newError(CodeBadRequest, name+" is required")
		}
		return nil
	}
	if len(s) > maxTextLength {
		return newError(CodeBadRequest, name+" is too long")
	}
	for _, r := range s {
		if unicode.IsControl(r) {
			return newError(CodeBadRequest, name+" contains control characters")
		}
	}
	return nil
}

func (p *UpsertParams) validate() *Error {
	for _, c := range []struct {
		name, value string
	}{{"vault_id", p.VaultID}, {"node_id", p.NodeID}, {"node_name", p.NodeName}, {"vault_uuid", p.VaultUUID}, {"vault_name", p.VaultName}} {
		if e := validText(c.name, c.value, true); e != nil {
			return e
		}
	}
	if !isVaultNumber(p.VaultUUID) {
		return newError(CodeBadRequest, "vault_uuid must be the Vaulthalla vault's numeric id (the key check binds it)")
	}
	if len(p.Versions) == 0 || len(p.Versions) > maxVersions {
		return newError(CodeBadRequest, "versions must list between 1 and 1000 key versions")
	}
	seen := map[int]bool{}
	for _, v := range p.Versions {
		if v.Version < 1 || v.Version > 1<<31-1 {
			return newError(CodeBadRequest, "a key version must be a positive number")
		}
		if seen[v.Version] {
			return newError(CodeBadRequest, fmt.Sprintf("version %d is listed twice", v.Version))
		}
		seen[v.Version] = true
		if len(v.Key) != KeyBytes {
			return newError(CodeBadRequest, fmt.Sprintf("version %d: key_b64 must hold a %d-byte key", v.Version, KeyBytes))
		}
		if e := validText(fmt.Sprintf("version %d: key_check", v.Version), v.KeyCheck, true); e != nil {
			return e
		}
		if a := v.Attestation; a != nil {
			if !validKeyID(uint64(a.KeyID)) {
				return newError(CodeBadRequest, fmt.Sprintf("version %d: attestation.key_id must be 1..2^31-1", v.Version))
			}
			if e := validText(fmt.Sprintf("version %d: attestation.signature", v.Version), a.Signature, true); e != nil {
				return e
			}
		}
	}
	// Only after every version's shape is valid: a key that doesn't match its check is refused before anything is
	// read from or written to 1Password.
	for _, v := range p.Versions {
		if !keyCheckMatches(v.Key, p.VaultUUID, v.Version, v.KeyCheck) {
			return newError(CodeKeyCheckMismatch,
				fmt.Sprintf("version %d of vault %s doesn't match its key check", v.Version, p.VaultUUID))
		}
	}
	if !seen[p.CurrentVersion] {
		return newError(CodeBadRequest, "current_version must be one of the listed versions")
	}
	return nil
}

func (p *UpsertParams) incoming(v int) (IncomingVersion, bool) {
	for _, iv := range p.Versions {
		if iv.Version == v {
			return iv, true
		}
	}
	return IncomingVersion{}, false
}

// merge computes the item to write: base is the existing item (nil to create one). It never changes or removes
// a stored version's key: an incoming version that differs from the stored one fails with version_conflict and
// nothing is written. Versions the daemon no longer lists stay, marked retired. changed is false when the item
// already says everything the request says (an idempotent re-upsert writes nothing).
func merge(base *parsedItem, p *UpsertParams, now time.Time, r *Redactor) (store.Item, bool, *Error) {
	var it store.Item
	stored := map[int]storedVersion{}
	if base != nil {
		it = base.Item.Clone()
		stored = base.Versions
		for _, v := range p.Versions {
			sv, ok := stored[v.Version]
			if !ok {
				continue
			}
			r.add(sv.Value)
			if !sameKey(sv.Value, v.Key) {
				return store.Item{}, false, newError(CodeVersionConflict,
					fmt.Sprintf("1Password already holds a different key for version %d of this vault", v.Version))
			}
			if sv.KeyCheck != "" && sv.KeyCheck != v.KeyCheck {
				return store.Item{}, false, newError(CodeVersionConflict,
					fmt.Sprintf("version %d is stored with a different key check", v.Version))
			}
		}
	} else {
		it = store.Item{Category: store.CategoryAPICredentials, VaultID: p.VaultID, Notes: restoreNotes(p.NodeName, p.VaultName)}
	}

	before := it.Clone()
	it.Title = itemTitle(p.VaultName, p.NodeName)
	it.Tags = mergeTags(it.Tags, p.NodeName)
	it.Sections = ensureSection(it.Sections, SectionMeta, "Vaulthalla")
	it.Sections = ensureSection(it.Sections, SectionVersions, "Key versions")

	current, _ := p.incoming(p.CurrentVersion)
	currentText := base64.StdEncoding.EncodeToString(current.Key)
	if sv, ok := stored[p.CurrentVersion]; ok {
		currentText = sv.Value // the stored text of the same key (checked equal above)
	}
	r.add(currentText)
	setField(&it, "", FieldCredential, "credential", store.FieldConcealed, currentText)

	meta := []struct{ id, title, value string }{
		{FieldNodeID, "node id", p.NodeID},
		{FieldNodeName, "node", p.NodeName},
		{FieldVaultUUID, "vault id", p.VaultUUID},
		{FieldVaultName, "vault", p.VaultName},
		{FieldKeyVersion, "key version", strconv.Itoa(p.CurrentVersion)},
		{FieldKeyCheck, "key check", current.KeyCheck},
		{FieldFormat, "format", Format},
	}
	for _, m := range meta {
		setField(&it, SectionMeta, m.id, m.title, store.FieldText, m.value)
	}
	// Placed now so its position is stable; its value changes only when something else does.
	backedUp, _ := it.Field(SectionMeta, FieldBackedUpAt)
	setField(&it, SectionMeta, FieldBackedUpAt, "backed up", store.FieldText, backedUp.Value)

	// Rebuild the versions section: every stored and incoming version, newest first. Stored values are kept as
	// they are; only new versions get a value. Fields in the section that aren't ours stay, after ours.
	all := map[int]bool{}
	for v := range stored {
		all[v] = true
	}
	for _, v := range p.Versions {
		all[v.Version] = true
	}
	versions := make([]int, 0, len(all))
	for v := range all {
		versions = append(versions, v)
	}
	sort.Sort(sort.Reverse(sort.IntSlice(versions)))

	var others, foreign []store.Field
	for _, f := range it.Fields {
		switch {
		case f.SectionID != SectionVersions:
			others = append(others, f)
		case isVersionFieldID(f.ID):
			// regenerated below
		default:
			foreign = append(foreign, f)
		}
	}
	section := make([]store.Field, 0, 3*len(versions))
	for _, v := range versions {
		in, listed := p.incoming(v)
		sv, isStored := stored[v]
		value, check := sv.Value, sv.KeyCheck
		if !isStored {
			value = base64.StdEncoding.EncodeToString(in.Key)
			r.add(value)
		}
		if check == "" {
			check = in.KeyCheck
		}
		state := StateRetired
		switch {
		case v == p.CurrentVersion:
			state = StateCurrent
		case listed && in.Needed:
			state = StateNeeded
		}
		// Attestation metadata: the node's latest (a re-backup refreshes it, e.g. one taken before the node attested
		// keys); otherwise what is stored. The key and its check above never change.
		attestation := sv.Attestation
		if listed && in.Attestation != nil {
			attestation = in.Attestation
		}
		name := versionField(v)
		section = append(section,
			store.Field{ID: name, Title: name, SectionID: SectionVersions, Type: store.FieldConcealed, Value: value},
			store.Field{ID: checkField(v), Title: name + " key check", SectionID: SectionVersions, Type: store.FieldText, Value: check},
			store.Field{ID: stateField(v), Title: name + " state", SectionID: SectionVersions, Type: store.FieldText, Value: state},
		)
		if attestation != nil {
			section = append(section,
				store.Field{ID: attestKeyField(v), Title: name + " attestation key", SectionID: SectionVersions, Type: store.FieldText, Value: strconv.FormatUint(uint64(attestation.KeyID), 10)},
				store.Field{ID: attestSigField(v), Title: name + " attestation", SectionID: SectionVersions, Type: store.FieldText, Value: attestation.Signature})
		}
	}
	it.Fields = append(append(others, section...), foreign...)

	changed := base == nil || !sameContent(before, it)
	if changed {
		setField(&it, SectionMeta, FieldBackedUpAt, "backed up", store.FieldText, now.UTC().Format(time.RFC3339))
	}
	return it, changed, nil
}

func isVersionFieldID(id string) bool {
	head, tail, _ := strings.Cut(id, "_")
	if !versionFieldID.MatchString(head) {
		return false
	}
	switch tail {
	case "", "check", "state", "attest_key_id", "attest_sig":
		return true
	}
	return false
}

func mergeTags(tags []string, nodeName string) []string {
	want := TagRoot + "/" + nodeSlug(nodeName)
	out := make([]string, 0, len(tags)+2)
	hasRoot := false
	for _, t := range tags {
		if strings.HasPrefix(t, TagRoot+"/") && t != want {
			continue // a renamed node's old tag
		}
		if t == TagRoot {
			hasRoot = true
		}
		if t == want {
			continue
		}
		out = append(out, t)
	}
	if !hasRoot {
		out = append(out, TagRoot)
	}
	return append(out, want)
}

func ensureSection(sections []store.Section, id, title string) []store.Section {
	for i, s := range sections {
		if s.ID == id {
			sections[i].Title = title
			return sections
		}
	}
	return append(sections, store.Section{ID: id, Title: title})
}

func setField(it *store.Item, sectionID, id, title, typ, value string) {
	for i, f := range it.Fields {
		if f.ID == id && f.SectionID == sectionID {
			it.Fields[i].Title, it.Fields[i].Type, it.Fields[i].Value = title, typ, value
			return
		}
	}
	it.Fields = append(it.Fields, store.Field{ID: id, Title: title, SectionID: sectionID, Type: typ, Value: value})
}

func sameContent(a, b store.Item) bool {
	if a.Title != b.Title || a.Notes != b.Notes || len(a.Tags) != len(b.Tags) ||
		len(a.Sections) != len(b.Sections) || len(a.Fields) != len(b.Fields) {
		return false
	}
	for i := range a.Tags {
		if a.Tags[i] != b.Tags[i] {
			return false
		}
	}
	for i := range a.Sections {
		if a.Sections[i] != b.Sections[i] {
			return false
		}
	}
	for i := range a.Fields {
		if a.Fields[i] != b.Fields[i] {
			return false
		}
	}
	return true
}
