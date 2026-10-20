package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
)

// Memory is an in-memory 1Password: vaults and items with optimistic versioning, nothing persisted. It backs the
// helper's unit tests and the fake build (`-tags fake`, `VH_OP_FAKE=1`) that the Swift tests drive.
//
// Accounts named "fake:<scenario>" fail Connect with the message the real SDK produces for that scenario, so the
// error mapping is exercised end to end: integration_disabled, app_not_running, app_not_installed, locked,
// denied, library_blocked.
type Memory struct {
	mu      sync.Mutex
	vaults  []Vault
	items   map[string]*Item // by item id
	nextID  int
	now     func() time.Time
	Writes  int // creates + puts, for tests that assert "no write happened"
	FailPut error
}

func NewMemory() *Memory {
	return &Memory{items: map[string]*Item{}, now: func() time.Time { return time.Now().UTC().Truncate(time.Second) }}
}

// ScenarioMessages are the raw error messages of 1Password's Go SDK v0.4.1 for each desktop-integration failure
// (internal/shared_lib_core.go and client_builder.go at that tag), plus representative messages for the ones the
// 1Password app itself produces (locked, denied), whose exact wording isn't published.
var ScenarioMessages = map[string]string{
	"integration_disabled": "desktop app connection channel is closed. Make sure Settings > Developer > Integrate with other apps is enabled, or contact 1Password support",
	"app_not_running":      "connection was unexpectedly dropped by the desktop app. Make sure the desktop app is running and Settings > Developer > Integrate with other apps is enabled, or contact 1Password support",
	"app_not_installed":    "1Password desktop application not found",
	"library_blocked":      "failed to open library",
	"locked":               "the 1Password app is locked",
	"denied":               "authorization was denied by the user",
}

func (m *Memory) Connect(_ context.Context, account string) (Backend, error) {
	if scenario, ok := strings.CutPrefix(account, "fake:"); ok {
		if msg, known := ScenarioMessages[scenario]; known {
			return nil, errors.New(msg)
		}
	}
	if strings.TrimSpace(account) == "" {
		return nil, errors.New("invalid account name")
	}
	return m, nil
}

func (m *Memory) ListVaults(context.Context) ([]Vault, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]Vault(nil), m.vaults...), nil
}

func (m *Memory) CreateVault(_ context.Context, title string) (Vault, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	v := Vault{ID: m.id("vault"), Title: title}
	m.vaults = append(m.vaults, v)
	return v, nil
}

// AddVault inserts a vault directly (test setup).
func (m *Memory) AddVault(title string) Vault {
	v, _ := m.CreateVault(context.Background(), title)
	return v
}

func (m *Memory) ListItems(_ context.Context, vaultID string) ([]ItemOverview, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.hasVault(vaultID) {
		return nil, fmt.Errorf("vault not found")
	}
	var out []ItemOverview
	for _, it := range m.items {
		if it.VaultID == vaultID {
			out = append(out, ItemOverview{ID: it.ID, Title: it.Title, Category: it.Category, VaultID: it.VaultID,
				Tags: append([]string(nil), it.Tags...), UpdatedAt: it.UpdatedAt})
		}
	}
	return out, nil
}

func (m *Memory) GetItem(_ context.Context, vaultID, itemID string) (Item, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	it, ok := m.items[itemID]
	if !ok || it.VaultID != vaultID {
		return Item{}, fmt.Errorf("item not found")
	}
	return it.Clone(), nil
}

func (m *Memory) CreateItem(_ context.Context, item Item) (Item, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.hasVault(item.VaultID) {
		return Item{}, fmt.Errorf("vault not found")
	}
	stored := item.Clone()
	stored.ID = m.id("item")
	stored.Version = 1
	stored.UpdatedAt = m.now()
	m.items[stored.ID] = &stored
	m.Writes++
	return stored.Clone(), nil
}

func (m *Memory) PutItem(_ context.Context, item Item) (Item, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.FailPut != nil {
		return Item{}, m.FailPut
	}
	cur, ok := m.items[item.ID]
	if !ok || cur.VaultID != item.VaultID {
		return Item{}, fmt.Errorf("item not found")
	}
	if cur.Version != item.Version {
		return Item{}, errors.New("incorrect item version")
	}
	stored := item.Clone()
	stored.Version = cur.Version + 1
	stored.UpdatedAt = m.now()
	m.items[stored.ID] = &stored
	m.Writes++
	return stored.Clone(), nil
}

// Put stores an item as is (test setup: hand-edited or foreign items).
func (m *Memory) Put(item Item) Item {
	m.mu.Lock()
	defer m.mu.Unlock()
	stored := item.Clone()
	if stored.ID == "" {
		stored.ID = m.id("item")
	}
	if stored.Version == 0 {
		stored.Version = 1
	}
	m.items[stored.ID] = &stored
	return stored.Clone()
}

func (m *Memory) hasVault(id string) bool {
	for _, v := range m.vaults {
		if v.ID == id {
			return true
		}
	}
	return false
}

func (m *Memory) id(prefix string) string {
	m.nextID++
	return fmt.Sprintf("%s%04d", prefix, m.nextID)
}
