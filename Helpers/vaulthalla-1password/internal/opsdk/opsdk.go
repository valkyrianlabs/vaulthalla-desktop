// Package opsdk adapts 1Password's Go SDK (github.com/1password/onepassword-sdk-go) to store.Backend, using
// desktop-app authorization: the SDK dlopen()s libop_sdk_ipc_client.dylib from the installed 1Password app and
// talks to the running app over its IPC; the user approves with Touch ID. That needs CGO (without it the SDK's
// WithDesktopAppIntegration returns an error), so build.sh sets CGO_ENABLED=1.
//
// Nothing in this package runs in tests: it is the only code that can contact 1Password.
package opsdk

import (
	"context"
	"fmt"

	"github.com/1password/onepassword-sdk-go"

	"github.com/vaulthalla/desktop/helpers/vaulthalla-1password/internal/store"
)

const IntegrationName = "Vaulthalla Desktop"

// Connector creates SDK clients. Note: the SDK loads 1Password's IPC library once per process and binds it to the
// first account name it was given (internal.GetSharedLibCore caches it), so one helper process serves one
// account; the server refuses an account switch and the caller restarts the helper instead.
type Connector struct {
	Version string
}

func (c Connector) Connect(ctx context.Context, account string) (store.Backend, error) {
	client, err := onepassword.NewClient(ctx,
		onepassword.WithDesktopAppIntegration(account),
		onepassword.WithIntegrationInfo(IntegrationName, c.Version),
	)
	if err != nil {
		return nil, err
	}
	return backend{client: client}, nil
}

type backend struct {
	client *onepassword.Client
}

func (b backend) ListVaults(ctx context.Context) ([]store.Vault, error) {
	vaults, err := b.client.Vaults().List(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]store.Vault, 0, len(vaults))
	for _, v := range vaults {
		out = append(out, store.Vault{ID: v.ID, Title: v.Title})
	}
	return out, nil
}

func (b backend) CreateVault(ctx context.Context, title string) (store.Vault, error) {
	description := "Vault key backups written by Vaulthalla Desktop. Don't edit the key fields by hand."
	v, err := b.client.Vaults().Create(ctx, onepassword.VaultCreateParams{Title: title, Description: &description})
	if err != nil {
		return store.Vault{}, err
	}
	return store.Vault{ID: v.ID, Title: v.Title}, nil
}

func (b backend) ListItems(ctx context.Context, vaultID string) ([]store.ItemOverview, error) {
	active := onepassword.NewItemListFilterTypeVariantByState(&onepassword.ItemListFilterByStateInner{Active: true})
	items, err := b.client.Items().List(ctx, vaultID, active)
	if err != nil {
		return nil, err
	}
	out := make([]store.ItemOverview, 0, len(items))
	for _, it := range items {
		if it.State != "" && it.State != onepassword.ItemStateActive {
			continue
		}
		out = append(out, store.ItemOverview{ID: it.ID, Title: it.Title, Category: string(it.Category),
			VaultID: it.VaultID, Tags: it.Tags, UpdatedAt: it.UpdatedAt})
	}
	return out, nil
}

func (b backend) GetItem(ctx context.Context, vaultID, itemID string) (store.Item, error) {
	it, err := b.client.Items().Get(ctx, vaultID, itemID)
	if err != nil {
		return store.Item{}, err
	}
	return fromSDK(it), nil
}

func (b backend) CreateItem(ctx context.Context, item store.Item) (store.Item, error) {
	notes := item.Notes
	params := onepassword.ItemCreateParams{
		Category: onepassword.ItemCategory(item.Category),
		VaultID:  item.VaultID,
		Title:    item.Title,
		Fields:   fieldsToSDK(item.Fields, nil),
		Sections: sectionsToSDK(item.Sections),
		Notes:    &notes,
		Tags:     item.Tags,
	}
	created, err := b.client.Items().Create(ctx, params)
	if err != nil {
		return store.Item{}, err
	}
	return fromSDK(created), nil
}

func (b backend) PutItem(ctx context.Context, item store.Item) (store.Item, error) {
	base, ok := item.Opaque.(onepassword.Item)
	if !ok {
		return store.Item{}, fmt.Errorf("internal: item %s was not read through the SDK", item.ID)
	}
	// Start from the item as read so websites, files and field details the helper doesn't model survive.
	updated := base
	updated.Title = item.Title
	updated.Notes = item.Notes
	updated.Tags = item.Tags
	updated.Sections = sectionsToSDK(item.Sections)
	updated.Fields = fieldsToSDK(item.Fields, base.Fields)
	updated.Version = item.Version
	put, err := b.client.Items().Put(ctx, updated)
	if err != nil {
		return store.Item{}, err
	}
	return fromSDK(put), nil
}

func fromSDK(it onepassword.Item) store.Item {
	out := store.Item{ID: it.ID, Title: it.Title, Category: string(it.Category), VaultID: it.VaultID,
		Notes: it.Notes, Tags: it.Tags, Version: it.Version, UpdatedAt: it.UpdatedAt, Opaque: it}
	for _, s := range it.Sections {
		out.Sections = append(out.Sections, store.Section{ID: s.ID, Title: s.Title})
	}
	for _, f := range it.Fields {
		section := ""
		if f.SectionID != nil {
			section = *f.SectionID
		}
		out.Fields = append(out.Fields, store.Field{ID: f.ID, Title: f.Title, SectionID: section,
			Type: string(f.FieldType), Value: f.Value})
	}
	return out
}

func sectionsToSDK(sections []store.Section) []onepassword.ItemSection {
	out := make([]onepassword.ItemSection, 0, len(sections))
	for _, s := range sections {
		out = append(out, onepassword.ItemSection{ID: s.ID, Title: s.Title})
	}
	return out
}

// fieldsToSDK converts fields, keeping the SDK's Details of fields that existed before (same id and section).
func fieldsToSDK(fields []store.Field, previous []onepassword.ItemField) []onepassword.ItemField {
	out := make([]onepassword.ItemField, 0, len(fields))
	for _, f := range fields {
		sf := onepassword.ItemField{ID: f.ID, Title: f.Title, FieldType: onepassword.ItemFieldType(f.Type), Value: f.Value}
		if f.SectionID != "" {
			section := f.SectionID
			sf.SectionID = &section
		}
		for _, p := range previous {
			pSection := ""
			if p.SectionID != nil {
				pSection = *p.SectionID
			}
			if p.ID == f.ID && pSection == f.SectionID && p.FieldType == sf.FieldType {
				sf.Details = p.Details
			}
		}
		out = append(out, sf)
	}
	return out
}
