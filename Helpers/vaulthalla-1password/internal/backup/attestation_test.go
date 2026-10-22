package backup

import (
	"encoding/json"
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
	// key_id is the daemon's integer: a string (or a negative number) is refused, not stored.
	for _, raw := range []string{`"ed25519:k1"`, `"1"`, `-1`} {
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

// An attestation edited by hand in 1Password (key id not a number) reads as none: the version is unattested (a
// salvage can still use it; the next backup stores the node's again), and the key itself is not an issue.
func TestAHandEditedAttestationReadsAsNone(t *testing.T) {
	h, vaultID := connected(t)
	var res UpsertResult
	h.ok("item.upsert", upsertParams(vaultID, 1, attested(1, 1, 7, "c2lnLXYx")), &res)
	it := h.item(vaultID, res.ItemID)
	for i, f := range it.Fields {
		if f.ID == "v1_attest_key_id" {
			it.Fields[i].Value = "ed25519:k1"
		}
	}
	h.mem.Put(it)
	var list ItemsListResult
	h.ok("items.list", map[string]string{"vault_id": vaultID}, &list)
	if got := list.Items[0]; got.Versions[0].Attestation != nil || len(got.Issues) != 0 {
		t.Fatalf("listed %+v", got)
	}
}
