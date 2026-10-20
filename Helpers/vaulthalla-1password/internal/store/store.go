// Package store is the narrow slice of 1Password the helper needs: vaults by title, and items with sections,
// fields and tags. The real implementation (package opsdk) wraps 1Password's Go SDK; Memory is an in-memory
// stand-in for unit tests and for the helper's fake build. Everything above this interface (find, merge, version
// rules, error mapping, the protocol) is tested against Memory without contacting 1Password.
package store

import (
	"context"
	"time"
)

// Connector opens a session with one 1Password account. With the SDK this is desktop-app authorization: the
// running 1Password app asks the user to approve (Touch ID) on first use.
type Connector interface {
	Connect(ctx context.Context, account string) (Backend, error)
}

// Backend is one authorized session.
type Backend interface {
	ListVaults(ctx context.Context) ([]Vault, error)
	CreateVault(ctx context.Context, title string) (Vault, error)
	// ListItems returns overviews of the active (not archived) items in a vault. Overviews carry no field values.
	ListItems(ctx context.Context, vaultID string) ([]ItemOverview, error)
	GetItem(ctx context.Context, vaultID, itemID string) (Item, error)
	CreateItem(ctx context.Context, item Item) (Item, error)
	// PutItem replaces an item. Item.Version must be the version that was read; a stale one fails (1Password's
	// "incorrect item version"), so concurrent edits are never silently overwritten.
	PutItem(ctx context.Context, item Item) (Item, error)
}

type Vault struct {
	ID    string
	Title string
}

// Category values used by the helper (1Password's SDK names).
const (
	CategoryAPICredentials = "ApiCredentials"
)

// Field types used by the helper (1Password's SDK names).
const (
	FieldText      = "Text"
	FieldConcealed = "Concealed"
)

type ItemOverview struct {
	ID        string
	Title     string
	Category  string
	VaultID   string
	Tags      []string
	UpdatedAt time.Time
}

type Section struct {
	ID    string
	Title string
}

type Field struct {
	ID        string
	Title     string
	SectionID string // "" for built-in fields such as `credential`
	Type      string
	Value     string
}

// Item is a full item. Opaque carries the backend's own representation of the item as read, so that PutItem keeps
// whatever this struct doesn't model (websites, files, field details) unchanged.
type Item struct {
	ID        string
	Title     string
	Category  string
	VaultID   string
	Sections  []Section
	Fields    []Field
	Notes     string
	Tags      []string
	Version   uint32
	UpdatedAt time.Time
	Opaque    any
}

// Clone deep-copies the slices so merges never alias the item they started from.
func (it Item) Clone() Item {
	c := it
	c.Sections = append([]Section(nil), it.Sections...)
	c.Fields = append([]Field(nil), it.Fields...)
	c.Tags = append([]string(nil), it.Tags...)
	return c
}

// Field returns the field with the given id and section, if present.
func (it Item) Field(sectionID, id string) (Field, bool) {
	for _, f := range it.Fields {
		if f.ID == id && f.SectionID == sectionID {
			return f, true
		}
	}
	return Field{}, false
}
