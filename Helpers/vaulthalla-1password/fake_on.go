//go:build fake

package main

import (
	"context"
	"encoding/json"
	"os"
	"strconv"
	"time"

	"github.com/vaulthalla/desktop/helpers/vaulthalla-1password/internal/backup"
	"github.com/vaulthalla/desktop/helpers/vaulthalla-1password/internal/store"
)

// fakeSetup switches the test build into fake mode when VH_OP_FAKE=1: an in-memory 1Password (store.Memory) plus
// fault-injection ops for the Swift client's tests:
//
//	fake.crash {code}  exits immediately with that status, without answering
//	fake.sleep {ms}    answers after ms milliseconds (timeouts)
//	fake.stats {}      {"writes": n}: creates + puts so far
//	fake.noise {}      writes a junk line before answering (the client must skip lines it can't route)
//	fake.key_check {key_b64, vault_uuid, version}
//	                   {"key_check": "..."}: the check of a test key, so the Swift tests needn't implement BLAKE2b
//
// Accounts named "fake:<scenario>" fail account.check like the real app would (see store.ScenarioMessages).
func fakeSetup(s *backup.Server) bool {
	if os.Getenv("VH_OP_FAKE") != "1" {
		return false
	}
	mem := store.NewMemory()
	s.Connector = mem
	s.Extra = map[string]backup.Handler{
		"fake.crash": func(_ context.Context, raw []byte, _ *backup.Redactor) (any, error) {
			var p struct {
				Code int `json:"code"`
			}
			_ = json.Unmarshal(raw, &p)
			if p.Code == 0 {
				p.Code = 70
			}
			os.Exit(p.Code)
			return nil, nil
		},
		"fake.sleep": func(ctx context.Context, raw []byte, _ *backup.Redactor) (any, error) {
			var p struct {
				MS int `json:"ms"`
			}
			_ = json.Unmarshal(raw, &p)
			select {
			case <-time.After(time.Duration(p.MS) * time.Millisecond):
			case <-ctx.Done():
			}
			return map[string]int{"slept_ms": p.MS}, nil
		},
		"fake.stats": func(context.Context, []byte, *backup.Redactor) (any, error) {
			return map[string]int{"writes": mem.Writes}, nil
		},
		"fake.key_check": func(_ context.Context, raw []byte, _ *backup.Redactor) (any, error) {
			var p struct {
				Key       []byte `json:"key_b64"`
				VaultUUID string `json:"vault_uuid"`
				Version   int    `json:"version"`
			}
			if err := json.Unmarshal(raw, &p); err != nil {
				return nil, &backup.Error{Code: backup.CodeBadRequest, Message: "invalid params"}
			}
			check, ok := backup.KeyCheck(p.Key, p.VaultUUID, p.Version)
			if !ok {
				return nil, &backup.Error{Code: backup.CodeBadRequest, Message: "not a 32-byte key, vault number and version"}
			}
			return map[string]string{"key_check": check}, nil
		},
		"fake.noise": func(context.Context, []byte, *backup.Redactor) (any, error) {
			os.Stdout.WriteString("{\"id\":\"noise-" + strconv.Itoa(os.Getpid()) + "\",\"ok\":true,\"result\":{}}\n")
			return map[string]bool{"noisy": true}, nil
		},
	}
	return true
}

func buildFlavor() string { return ", fake build" }
