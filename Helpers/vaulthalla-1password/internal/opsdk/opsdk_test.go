package opsdk

import (
	"testing"

	"github.com/1password/onepassword-sdk-go"

	"github.com/valkyrianlabs/vaulthalla-desktop/helpers/vaulthalla-1password/internal/store"
)

// Conversion only: nothing here creates an SDK client or contacts 1Password.
func TestConversionKeepsSectionsAndDetails(t *testing.T) {
	section := "key_versions"
	details := onepassword.NewItemFieldDetailsTypeVariantOTP(&onepassword.OTPFieldDetails{})
	sdkItem := onepassword.Item{
		ID: "i", Title: "t", Category: onepassword.ItemCategoryAPICredentials, VaultID: "v", Version: 4,
		Sections: []onepassword.ItemSection{{ID: section, Title: "Key versions"}},
		Fields: []onepassword.ItemField{
			{ID: "credential", Title: "credential", FieldType: onepassword.ItemFieldTypeConcealed, Value: "AQID"},
			{ID: "v1", Title: "v1", SectionID: &section, FieldType: onepassword.ItemFieldTypeConcealed, Value: "AQID"},
			{ID: "otp", Title: "otp", FieldType: onepassword.ItemFieldTypeTOTP, Value: "otpauth://x", Details: &details},
		},
		Tags: []string{"vaulthalla"},
	}
	it := fromSDK(sdkItem)
	if it.Category != store.CategoryAPICredentials || it.Version != 4 || len(it.Fields) != 3 ||
		it.Fields[1].SectionID != section || it.Fields[0].SectionID != "" || it.Fields[0].Type != store.FieldConcealed {
		t.Fatalf("fromSDK: %+v", it)
	}
	back := fieldsToSDK(it.Fields, sdkItem.Fields)
	if back[1].SectionID == nil || *back[1].SectionID != section || back[0].SectionID != nil {
		t.Fatal("section ids not restored")
	}
	if back[2].Details == nil {
		t.Fatal("details of an existing field were dropped")
	}
	if got := sectionsToSDK(it.Sections); len(got) != 1 || got[0].Title != "Key versions" {
		t.Fatalf("sections %+v", got)
	}
	if store.FieldText != string(onepassword.ItemFieldTypeText) || store.FieldConcealed != string(onepassword.ItemFieldTypeConcealed) {
		t.Fatal("field type names drifted from the SDK")
	}
}
