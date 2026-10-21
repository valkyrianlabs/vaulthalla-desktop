package backup

import (
	"strings"
	"testing"

	"github.com/vaulthalla/desktop/helpers/vaulthalla-1password/internal/store"
)

func attested(n int, k byte, node, keyID, sig string) ver {
	x := v(n, k)
	x.NodeID = node
	x.Attestation = &Attestation{KeyID: keyID, Signature: sig}
	return x
}

// Attestations are non-secret metadata next to each version's key: stored, listed and revealed byte for byte,
// never verified by the helper, and added to a version backed up without one when the node later attests it.
func TestAttestationsAreStoredListedAndRevealed(t *testing.T) {
	h, vaultID := connected(t)
	var res UpsertResult
	// v1 backed up before the node attested keys.
	h.ok("item.upsert", upsertParams(vaultID, 1, v(1, 1)), &res)
	var list ItemsListResult
	h.ok("items.list", map[string]string{"vault_id": vaultID}, &list)
	if got := list.Items[0].Versions[0]; got.Attestation != nil || got.NodeID != "" {
		t.Fatalf("unattested version listed with %+v", got)
	}

	sig1, sig2 := "c2lnbmF0dXJlLW9mLXYx+/==", "c2lnbmF0dXJlLW9mLXYy"
	// The node now attests: v2 arrives attested, and v1 again with its (new) attestation.
	h.ok("item.upsert", upsertParams(vaultID, 2, attested(2, 2, "srv-node-a", "ed25519:k1", sig2),
		attested(1, 1, "srv-node-a", "ed25519:k1", sig1)), &res)
	if !res.Written {
		t.Fatal("adding attestations wrote nothing")
	}
	it := h.item(vaultID, res.ItemID)
	if field(t, it, SectionVersions, "v1") != b64(key(1)) || field(t, it, SectionVersions, "v1_check") != kc(1, 1) {
		t.Fatal("refreshing the attestation changed the key")
	}
	if field(t, it, SectionVersions, "v1_attest_sig") != sig1 || field(t, it, SectionVersions, "v2_attest_key_id") != "ed25519:k1" ||
		field(t, it, SectionVersions, "v2_node_id") != "srv-node-a" {
		t.Fatal("attestation fields not stored as given")
	}
	for _, f := range it.Fields {
		if strings.Contains(f.ID, "attest") || strings.HasSuffix(f.ID, "_node_id") {
			if f.Type == store.FieldConcealed {
				t.Fatalf("%s is concealed; attestations are metadata", f.ID)
			}
		}
	}

	h.ok("items.list", map[string]string{"vault_id": vaultID}, &list)
	got := list.Items[0].Versions
	if len(got) != 2 || got[0].Attestation == nil || got[0].Attestation.Signature != sig2 || got[1].Attestation.Signature != sig1 ||
		got[1].NodeID != "srv-node-a" || len(list.Items[0].Issues) != 0 {
		t.Fatalf("listed %+v", got)
	}

	var revealed struct {
		Versions []struct {
			Version     int          `json:"version"`
			NodeID      string       `json:"node_id"`
			Attestation *Attestation `json:"attestation"`
		} `json:"versions"`
	}
	h.ok("item.reveal", map[string]any{"vault_id": vaultID, "item_id": res.ItemID}, &revealed)
	if revealed.Versions[1].Attestation == nil || revealed.Versions[1].Attestation.Signature != sig1 || revealed.Versions[1].NodeID != "srv-node-a" {
		t.Fatalf("revealed %+v", revealed.Versions)
	}

	// A later upsert without attestations keeps them; the same upsert again writes nothing.
	writes := h.mem.Writes
	h.ok("item.upsert", upsertParams(vaultID, 2, v(2, 2), v(1, 1)), &res)
	h.ok("item.upsert", upsertParams(vaultID, 2, attested(2, 2, "srv-node-a", "ed25519:k1", sig2),
		attested(1, 1, "srv-node-a", "ed25519:k1", sig1)), &res)
	if res.Written || h.mem.Writes != writes {
		t.Fatal("an upsert that changes nothing wrote")
	}
	if field(t, h.item(vaultID, res.ItemID), SectionVersions, "v1_attest_sig") != sig1 {
		t.Fatal("attestation lost")
	}
}

func TestAttestationsAreValidated(t *testing.T) {
	h, vaultID := connected(t)
	h.fails("item.upsert", upsertParams(vaultID, 1, attested(1, 1, "n", "", "sig")), CodeBadRequest)
	h.fails("item.upsert", upsertParams(vaultID, 1, attested(1, 1, "n", "k", "")), CodeBadRequest)
	h.fails("item.upsert", upsertParams(vaultID, 1, attested(1, 1, "a\nb", "k", "s")), CodeBadRequest)
	if h.mem.Writes != 0 {
		t.Fatal("an invalid attestation wrote")
	}
}
