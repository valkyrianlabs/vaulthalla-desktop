package backup

import (
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"

	"golang.org/x/crypto/blake2b"
)

// The key check identifies one version of a vault key without revealing it (the daemon's vault/KeyCheck.hpp):
//
//	key_check = lowercase hex of BLAKE2b-128 keyed by the 32 key bytes,
//	            over "vh-key-check-v1" ‖ vault_id as ASCII decimal ‖ UInt32BE(version)
//
// The helper computes it itself so key bytes stay inside the helper: every incoming version is checked before
// anything is written (key_check_mismatch otherwise), and every stored version is checked again when it is read
// back, listed or revealed.
const (
	keyCheckDomain = "vh-key-check-v1"
	// KeyBytes is the size of a Vaulthalla vault key (AES-256).
	KeyBytes = 32
)

// isVaultNumber reports whether s is a Vaulthalla vault id as the key check binds it: ASCII decimal, no sign, no
// leading zeros.
func isVaultNumber(s string) bool {
	if s == "" || len(s) > 20 || (len(s) > 1 && s[0] == '0') {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// KeyCheck computes the key check of key as version `version` of vault `vaultID` (decimal). ok is false when the
// key isn't 32 bytes, the vault id isn't a vault number or the version doesn't fit in 32 bits.
func KeyCheck(key []byte, vaultID string, version int) (check string, ok bool) {
	if len(key) != KeyBytes || !isVaultNumber(vaultID) || version < 1 || version > 1<<32-1 {
		return "", false
	}
	h, err := blake2b.New(16, key)
	if err != nil {
		return "", false
	}
	var v [4]byte
	binary.BigEndian.PutUint32(v[:], uint32(version))
	h.Write([]byte(keyCheckDomain))
	h.Write([]byte(vaultID))
	h.Write(v[:])
	return hex.EncodeToString(h.Sum(nil)), true
}

// keyCheckMatches recomputes the key check and compares it with `want` in constant time.
func keyCheckMatches(key []byte, vaultID string, version int, want string) bool {
	got, ok := KeyCheck(key, vaultID, version)
	return ok && len(got) == len(want) && subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

// storedKeyCheckMatches is keyCheckMatches for a stored base64 value; the decoded bytes are wiped.
func storedKeyCheckMatches(value, vaultID string, version int, want string) bool {
	b, err := base64.StdEncoding.DecodeString(value)
	defer wipe(b)
	return err == nil && keyCheckMatches(b, vaultID, version, want)
}
