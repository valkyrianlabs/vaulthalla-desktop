package backup

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/vaulthalla/desktop/helpers/vaulthalla-1password/internal/store"
)

func attested(n int, k byte, keyID uint32, sig string) ver {
	x := v(n, k)
	x.Attestation = &Attestation{KeyID: keyID, Signature: sig}
	return x
}

// Attestations are non-secret metadata next to each version's key: stored, listed and revealed unchanged (key_id
// the daemon's integer, the signature its base64 text), never verified by the helper, and added to a version backed
// up without one when the node later attests it.
func TestAttestationsAreStoredListedAndRevealed(t *testing.T) {
	h, vaultID := connected(t)
	var res UpsertResult
	// v1 backed up before the node attested keys.
	h.ok("item.upsert", upsertParams(vaultID, 1, v(1, 1)), &res)
	var list ItemsListResult
	h.ok("items.list", map[string]string{"vault_id": vaultID}, &list)
	if got := list.Items[0].Versions[0]; got.Attestation != nil {
		t.Fatalf("unattested version listed with %+v", got)
	}

	sig1, sig2 := "c2lnbmF0dXJlLW9mLXYx+/==", "c2lnbmF0dXJlLW9mLXYy"
	// The node now attests: v2 arrives attested, and v1 again with its (new) attestation.
	h.ok("item.upsert", upsertParams(vaultID, 2, attested(2, 2, 3, sig2), attested(1, 1, 3, sig1)), &res)
	if !res.Written {
		t.Fatal("adding attestations wrote nothing")
	}
	it := h.item(vaultID, res.ItemID)
	if field(t, it, SectionVersions, "v1") != b64(key(1)) || field(t, it, SectionVersions, "v1_check") != kc(1, 1) {
		t.Fatal("refreshing the attestation changed the key")
	}
	if field(t, it, SectionVersions, "v1_attest_sig") != sig1 || field(t, it, SectionVersions, "v2_attest_key_id") != "3" {
		t.Fatal("attestation fields not stored as given")
	}
	for _, f := range it.Fields {
		if strings.Contains(f.ID, "attest") {
			if f.Type == store.FieldConcealed {
				t.Fatalf("%s is concealed; attestations are metadata", f.ID)
			}
		}
	}

	h.ok("items.list", map[string]string{"vault_id": vaultID}, &list)
	got := list.Items[0].Versions
	if len(got) != 2 || got[0].Attestation == nil || got[0].Attestation.Signature != sig2 || got[1].Attestation.Signature != sig1 ||
		got[1].Attestation.KeyID != 3 || len(list.Items[0].Issues) != 0 {
		t.Fatalf("listed %+v", got)
	}

	var revealed struct {
		Versions []struct {
			Version     int             `json:"version"`
			Attestation json.RawMessage `json:"attestation"`
		} `json:"versions"`
	}
	h.ok("item.reveal", map[string]any{"vault_id": vaultID, "item_id": res.ItemID}, &revealed)
	// The daemon's shape exactly: key_id a JSON number, the signature as given.
	if got := string(revealed.Versions[1].Attestation); got != `{"key_id":3,"signature":"`+sig1+`"}` {
		t.Fatalf("revealed v1's attestation as %s", got)
	}

	// A later upsert without attestations keeps them; the same upsert again writes nothing.
	writes := h.mem.Writes
	h.ok("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), &res)
	h.ok("item.upsert", upsertParams(vaultID, 2, attested(2, 2, 3, sig2), attested(1, 1, 3, sig1)), &res)
	if res.Written || h.mem.Writes != writes {
		t.Fatal("an upsert that changes nothing wrote")
	}
	if field(t, h.item(vaultID, res.ItemID), SectionVersions, "v1_attest_sig") != sig1 {
		t.Fatal("attestation lost")
	}
}

func TestAttestationsAreValidated(t *testing.T) {
	h, vaultID := connected(t)
	h.fails("item.upsert", upsertParams(vaultID, 1, attested(1, 1, 1, "")), CodeBadRequest)
	h.fails("item.upsert", upsertParams(vaultID, 1, attested(1, 1, 1, "a\nb")), CodeBadRequest)
	// key_id is the daemon's SERIAL (1..2^31-1): a string, a negative number, 0 or anything past 2^31-1 is refused,
	// not stored.
	for _, raw := range []string{`"ed25519:k1"`, `"1"`, `-1`, `0`, `2147483648`, `4294967295`} {
		params := map[string]any{"vault_id": vaultID, "node_id": "node-1", "node_name": "Home Lab", "vault_uuid": testVault,
			"vault_name": "Photos", "current_version": 1, "versions": []map[string]any{{
				"version": 1, "key_b64": b64(key(1)), "key_check": kc(1, 1), "needed": true,
				"attestation": json.RawMessage(`{"key_id":` + raw + `,"signature":"c2ln"}`)}}}
		h.fails("item.upsert", params, CodeBadRequest)
	}
	if h.mem.Writes != 0 {
		t.Fatal("an invalid attestation wrote")
	}
}

// An attestation edited by hand in 1Password (key id not a number, or outside the daemon's 1..2^31-1) reads as none:
// the version is unattested (a salvage can still use it; the node's can be stored again), and the key itself is not
// an issue.
func TestAHandEditedAttestationReadsAsNone(t *testing.T) {
	for _, edited := range []string{"ed25519:k1", "0", "2147483648", "4294967295", "-3"} {
		t.Run(edited, func(t *testing.T) {
			h, vaultID := connected(t)
			var res UpsertResult
			h.ok("item.upsert", upsertParams(vaultID, 1, attested(1, 1, 7, "c2lnLXYx")), &res)
			it := h.item(vaultID, res.ItemID)
			for i, f := range it.Fields {
				if f.ID == "v1_attest_key_id" {
					it.Fields[i].Value = edited
				}
			}
			h.mem.Put(it)
			var list ItemsListResult
			h.ok("items.list", map[string]string{"vault_id": vaultID}, &list)
			if got := list.Items[0]; got.Versions[0].Attestation != nil || len(got.Issues) != 0 {
				t.Fatalf("listed %+v", got)
			}
			// item.attest fills it in again.
			var out AttestResult
			h.ok("item.attest", attestParamsFor(vaultID, res.ItemID, attestEntry(1, 1, 9, sig64(1))), &out)
			if fmt.Sprint(out.Stored) != "[1]" || field(t, h.item(vaultID, res.ItemID), SectionVersions, "v1_attest_key_id") != "9" {
				t.Fatalf("attest after a hand edit: %+v", out)
			}
		})
	}
	// The bounds themselves are fine.
	h, vaultID := connected(t)
	var res UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 2, attested(2, 2, 2147483647, "c2ln"), attested(1, 1, 1, "c2ln")), &res)
	var list ItemsListResult
	h.ok("items.list", map[string]string{"vault_id": vaultID}, &list)
	if v := list.Items[0].Versions; v[0].Attestation == nil || v[0].Attestation.KeyID != 2147483647 || v[1].Attestation == nil {
		t.Fatalf("listed %+v", v)
	}
}

// sig64 is a well-formed signature (64 bytes, base64) distinct per seed.
func sig64(seed byte) string { return b64(bytes.Repeat([]byte{seed}, 64)) }

func attestParamsFor(vaultID, itemID string, versions ...map[string]any) map[string]any {
	return map[string]any{"vault_id": vaultID, "item_id": itemID, "node_id": "node-1", "vault_uuid": testVault,
		"versions": versions}
}

func attestEntry(n int, k byte, keyID uint32, sig string) map[string]any {
	return map[string]any{"version": n, "key_check": kc(n, k), "attestation": map[string]any{"key_id": keyID, "signature": sig}}
}

// item.attest adds the node's attestations to a backup that has none (or malformed ones), as metadata only: the keys,
// key checks and states stay byte for byte, a well-formed stored attestation is never replaced, and asking again
// writes nothing.
func TestItemAttestFillsMissingAndMalformedAttestationsOnly(t *testing.T) {
	h, vaultID := connected(t)
	var res UpsertResult
	// v3 attested at backup time; v2 with a malformed attestation (a 3-byte signature); v1 with none.
	h.ok("item.upsert", upsertParams(vaultID, 3, attested(3, 3, 5, sig64(3)), attested(2, 2, 4, "c2ln"), v(1, 1)), &res)
	before := h.item(vaultID, res.ItemID)
	writes := h.mem.Writes

	var out AttestResult
	h.ok("item.attest", attestParamsFor(vaultID, res.ItemID,
		attestEntry(3, 3, 9, sig64(33)), attestEntry(2, 2, 9, sig64(22)), attestEntry(1, 1, 9, sig64(11))), &out)
	if !out.Written || fmt.Sprint(out.Stored) != "[2 1]" || fmt.Sprint(out.Kept) != "[3]" || h.mem.Writes != writes+1 {
		t.Fatalf("attest result %+v (writes %d → %d)", out, writes, h.mem.Writes)
	}
	after := h.item(vaultID, res.ItemID)
	for _, id := range []string{"v3", "v3_check", "v3_state", "v2", "v2_check", "v2_state", "v1", "v1_check", "v1_state"} {
		if field(t, after, SectionVersions, id) != field(t, before, SectionVersions, id) {
			t.Fatalf("%s changed", id)
		}
	}
	if field(t, after, "", FieldCredential) != field(t, before, "", FieldCredential) ||
		field(t, after, SectionMeta, FieldBackedUpAt) != field(t, before, SectionMeta, FieldBackedUpAt) {
		t.Fatal("attesting touched the current key or the backup time")
	}
	if field(t, after, SectionVersions, "v3_attest_sig") != sig64(3) || field(t, after, SectionVersions, "v3_attest_key_id") != "5" {
		t.Fatal("a well-formed stored attestation was replaced")
	}
	if field(t, after, SectionVersions, "v2_attest_key_id") != "9" || field(t, after, SectionVersions, "v2_attest_sig") != sig64(22) ||
		field(t, after, SectionVersions, "v1_attest_sig") != sig64(11) {
		t.Fatal("missing or malformed attestations not filled in")
	}
	// v1's attestation sits with v1's fields, as merge places it.
	var order []string
	for _, f := range after.Fields {
		if f.SectionID == SectionVersions {
			order = append(order, f.ID)
		}
	}
	if got := strings.Join(order, ","); !strings.HasSuffix(got, "v1,v1_check,v1_state,v1_attest_key_id,v1_attest_sig") {
		t.Fatalf("field order %s", got)
	}
	// A later backup leaves the item as it is: the layout is merge's own.
	h.ok("item.upsert", upsertParams(vaultID, 3, v(3, 3), v(2, 2), v(1, 1)), &res)
	if res.Written {
		t.Fatal("an upsert after attesting rewrote the item")
	}
	// The same request again: everything is kept, nothing written.
	h.ok("item.attest", attestParamsFor(vaultID, res.ItemID, attestEntry(1, 1, 9, sig64(11))), &out)
	if out.Written || len(out.Stored) != 0 || fmt.Sprint(out.Kept) != "[1]" || h.mem.Writes != writes+1 {
		t.Fatalf("a repeated attest wrote: %+v", out)
	}
	var list ItemsListResult
	h.ok("items.list", map[string]string{"vault_id": vaultID}, &list)
	if got := list.Items[0].Versions[2].Attestation; got == nil || got.KeyID != 9 || got.Signature != sig64(11) {
		t.Fatalf("listed v1 attestation %+v", got)
	}
}

// Nothing is written unless every named version is stored under the given key check, for this node and vault, with a
// well-formed attestation.
func TestItemAttestRefusesWithoutWriting(t *testing.T) {
	h, vaultID := connected(t)
	var res UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), &res)
	writes := h.mem.Writes
	ok := attestEntry(2, 2, 9, sig64(2))
	// Another key check for v1 (the node holds another key under that version).
	h.fails("item.attest", attestParamsFor(vaultID, res.ItemID, ok, attestEntry(1, 7, 9, sig64(1))), CodeVersionConflict)
	// A version the item doesn't hold.
	h.fails("item.attest", attestParamsFor(vaultID, res.ItemID, ok, attestEntry(3, 3, 9, sig64(3))), CodeNotFound)
	// Another node's item.
	other := attestParamsFor(vaultID, res.ItemID, ok)
	other["node_id"] = "node-2"
	h.fails("item.attest", other, CodeVersionConflict)
	// Malformed attestations: key id out of range, a signature that isn't 64 bytes, none at all.
	for _, bad := range []map[string]any{
		attestEntry(2, 2, 0, sig64(2)), attestEntry(2, 2, 1<<31, sig64(2)), attestEntry(2, 2, 9, "c2ln"),
		{"version": 2, "key_check": kc(2, 2)},
	} {
		h.fails("item.attest", attestParamsFor(vaultID, res.ItemID, bad), CodeBadRequest)
	}
	// Keys never travel in this op.
	withKey := attestEntry(2, 2, 9, sig64(2))
	withKey["key_b64"] = b64(key(2))
	h.fails("item.attest", attestParamsFor(vaultID, res.ItemID, withKey), CodeBadRequest)
	if h.mem.Writes != writes {
		t.Fatal("a refused attest wrote")
	}
}
