package backup

import (
	"context"
	"encoding/base64"
	"fmt"
	"strconv"

	"github.com/valkyrianlabs/vaulthalla-desktop/helpers/vaulthalla-1password/internal/store"
)

// --- item.attest ---
//
// Adds the node's attestations to versions an item already holds, as metadata only: no key travels in the request,
// and no key, key check, state or other field changes. The app sends attestations the node reported for versions
// whose key check it compared with the item's (or that the node just restored on them); the helper checks again that
// each named version is stored under that key check. A stored attestation that is well-formed is never replaced (the
// version is reported as kept); a missing or malformed one is filled in. All or nothing: an unknown version or a
// different key check fails the request and nothing is written.

// The daemon's signing key ids are a SERIAL (1..2^31 - 1), and its signatures Ed25519 (64 bytes, base64).
const (
	maxAttestationKeyID = 1<<31 - 1
	signatureBytes      = 64
)

// wellFormed: an attestation the daemon could verify at all. A malformed one (a key id out of range, a signature
// that isn't 64 bytes of base64) is as good as none: the daemon reads it as unattested.
func (a *Attestation) wellFormed() bool {
	if a == nil || !validKeyID(uint64(a.KeyID)) {
		return false
	}
	sig, err := base64.StdEncoding.DecodeString(a.Signature)
	return err == nil && len(sig) == signatureBytes
}

type attestVersion struct {
	Version  int    `json:"version"`
	KeyCheck string `json:"key_check"`
	// Required: the node's attestation of this version.
	Attestation *Attestation `json:"attestation"`
}

type attestParams struct {
	VaultID   string          `json:"vault_id"`
	ItemID    string          `json:"item_id"`
	NodeID    string          `json:"node_id"`
	VaultUUID string          `json:"vault_uuid"`
	Versions  []attestVersion `json:"versions"`
}

// AttestResult is what the item holds afterwards, read back. Stored: the versions that got the given attestation;
// kept: versions whose own well-formed attestation stayed.
type AttestResult struct {
	ItemID         string        `json:"item_id"`
	VaultID        string        `json:"vault_id"`
	Written        bool          `json:"written"`
	Stored         []int         `json:"stored"`
	Kept           []int         `json:"kept"`
	StoredVersions []VersionMeta `json:"stored_versions"`
	UpdatedAt      string        `json:"updated_at,omitempty"`
}

func (p *attestParams) validate() *Error {
	for _, c := range []struct{ name, value string }{
		{"vault_id", p.VaultID}, {"item_id", p.ItemID}, {"node_id", p.NodeID}, {"vault_uuid", p.VaultUUID},
	} {
		if e := validText(c.name, c.value, true); e != nil {
			return e
		}
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
		if e := validText(fmt.Sprintf("version %d: key_check", v.Version), v.KeyCheck, true); e != nil {
			return e
		}
		if !v.Attestation.wellFormed() {
			return newError(CodeBadRequest, fmt.Sprintf(
				"version %d: attestation must be {key_id: 1..2^31-1, signature: 64 bytes base64}", v.Version))
		}
	}
	return nil
}

func (s *Server) itemAttest(ctx context.Context, raw []byte, r *Redactor) (any, error) {
	var p attestParams
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
	it, err := b.GetItem(ctx, p.VaultID, p.ItemID)
	if err != nil {
		return nil, err
	}
	parsed, ok := parseItem(it)
	if !ok {
		return nil, newError(CodeNotFound, "that item isn't a Vaulthalla key backup")
	}
	for _, sv := range parsed.Versions {
		r.add(sv.Value)
	}
	if parsed.NodeID != p.NodeID || parsed.VaultUUID != p.VaultUUID {
		return nil, newError(CodeVersionConflict, "that item backs up another node or vault; nothing was written")
	}

	desired := it.Clone()
	var stored, kept []int
	for _, v := range p.Versions {
		sv, ok := parsed.Versions[v.Version]
		if !ok {
			return nil, newError(CodeNotFound, fmt.Sprintf("the item has no key version %d; nothing was written", v.Version))
		}
		if sv.KeyCheck != v.KeyCheck {
			return nil, newError(CodeVersionConflict,
				fmt.Sprintf("version %d is stored with a different key check; nothing was written", v.Version))
		}
		if sv.Attestation.wellFormed() {
			kept = append(kept, v.Version)
			continue
		}
		setAttestation(&desired, v.Version, v.Attestation)
		stored = append(stored, v.Version)
	}

	written := it
	if len(stored) > 0 {
		if written, err = b.PutItem(ctx, desired); err != nil {
			return nil, err
		}
	}
	readBack, err := b.GetItem(ctx, p.VaultID, written.ID)
	if err != nil {
		return nil, err
	}
	after, ok := parseItem(readBack)
	if !ok {
		return nil, newError(CodeVerifyFailed, "the item read back from 1Password has no Vaulthalla identifiers")
	}
	for _, sv := range after.Versions {
		r.add(sv.Value)
	}
	if e := verifyAttested(parsed, after, p, stored); e != nil {
		return nil, e
	}
	return AttestResult{ItemID: after.Item.ID, VaultID: after.Item.VaultID, Written: len(stored) > 0,
		Stored: nonNil(stored), Kept: nonNil(kept), StoredVersions: after.meta().Versions,
		UpdatedAt: timeString(after.Item.UpdatedAt)}, nil
}

// setAttestation writes version v's attestation fields: in place when they exist (a malformed attestation), otherwise
// right after the version's own fields, where merge puts them.
func setAttestation(it *store.Item, v int, a *Attestation) {
	name := versionField(v)
	want := []store.Field{
		{ID: attestKeyField(v), Title: name + " attestation key", SectionID: SectionVersions, Type: store.FieldText,
			Value: strconv.FormatUint(uint64(a.KeyID), 10)},
		{ID: attestSigField(v), Title: name + " attestation", SectionID: SectionVersions, Type: store.FieldText,
			Value: a.Signature},
	}
	for _, f := range want {
		if _, ok := it.Field(SectionVersions, f.ID); ok {
			setField(it, SectionVersions, f.ID, f.Title, f.Type, f.Value)
			continue
		}
		at := len(it.Fields)
		for i, existing := range it.Fields {
			if existing.SectionID != SectionVersions {
				continue
			}
			switch existing.ID {
			case name, checkField(v), stateField(v), attestKeyField(v):
				at = i + 1
			}
		}
		it.Fields = append(it.Fields[:at], append([]store.Field{f}, it.Fields[at:]...)...)
	}
}

// verifyAttested checks the read-back item: every key and key check as before, the stored attestations as sent, and
// the kept ones unchanged.
func verifyAttested(before, after parsedItem, p attestParams, stored []int) *Error {
	fail := func(what string) *Error {
		return newError(CodeVerifyFailed, "1Password's copy doesn't match what was written: "+what)
	}
	if after.NodeID != before.NodeID || after.VaultUUID != before.VaultUUID || after.CurrentVersion != before.CurrentVersion ||
		after.KeyCheck != before.KeyCheck || after.Credential != before.Credential {
		return fail("identifiers or current version")
	}
	if len(after.Versions) != len(before.Versions) {
		return fail("the key versions")
	}
	for n, b := range before.Versions {
		a, ok := after.Versions[n]
		if !ok || a.Value != b.Value || a.KeyCheck != b.KeyCheck || a.State != b.State {
			return fail(versionField(n) + " changed")
		}
	}
	isStored := map[int]bool{}
	for _, n := range stored {
		isStored[n] = true
	}
	for _, v := range p.Versions {
		got := after.Versions[v.Version].Attestation
		want := before.Versions[v.Version].Attestation
		if isStored[v.Version] {
			want = v.Attestation
		}
		if !got.equal(want) {
			return fail(versionField(v.Version) + "'s attestation")
		}
	}
	return nil
}

func nonNil(s []int) []int {
	if s == nil {
		return []int{}
	}
	return s
}
