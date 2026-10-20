package backup

import (
	"encoding/base64"
	"encoding/json"
)

// Memory hygiene, best effort. Key bytes are held in []byte that the helper zeroes when done (request lines, the
// decoded keys, response buffers). Go limits how far that goes: the garbage collector may have copied a slice
// before it was zeroed, and 1Password's SDK takes field values as Go strings, which are immutable and can't be
// wiped, then marshals them again on their way to the 1Password app. The helper is short-lived (launched for a
// sync, exits when stdin closes), which bounds how long such copies live.

// wipe zeroes b.
func wipe(b []byte) { clear(b) }

// secureBuf is an append-only buffer that zeroes its old backing array whenever it grows, so a response holding
// key material doesn't leave partial copies behind in abandoned arrays.
type secureBuf struct {
	b []byte
}

func newSecureBuf(capacity int) *secureBuf { return &secureBuf{b: make([]byte, 0, capacity)} }

func (s *secureBuf) grow(n int) {
	if len(s.b)+n <= cap(s.b) {
		return
	}
	next := make([]byte, len(s.b), 2*cap(s.b)+n)
	copy(next, s.b)
	wipe(s.b[:cap(s.b)])
	s.b = next
}

func (s *secureBuf) write(p []byte) {
	s.grow(len(p))
	s.b = append(s.b, p...)
}

func (s *secureBuf) writeString(p string) {
	s.grow(len(p))
	s.b = append(s.b, p...)
}

func (s *secureBuf) writeByte(c byte) {
	s.grow(1)
	s.b = append(s.b, c)
}

// writeJSON appends v marshalled with encoding/json. Only for values without key material: encoding/json keeps
// pooled scratch buffers this code can't wipe.
func (s *secureBuf) writeJSON(v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	s.write(data)
	return nil
}

// writeBase64 appends a JSON string holding key in standard base64, encoding straight into this buffer.
func (s *secureBuf) writeBase64(key []byte) {
	n := base64.StdEncoding.EncodedLen(len(key))
	s.grow(n + 2)
	s.b = append(s.b, '"')
	start := len(s.b)
	s.b = s.b[:start+n]
	base64.StdEncoding.Encode(s.b[start:], key)
	s.b = append(s.b, '"')
}

func (s *secureBuf) bytes() []byte { return s.b }

func (s *secureBuf) wipe() {
	wipe(s.b[:cap(s.b)])
	s.b = s.b[:0]
}

// jsonAppender is implemented by results that carry key material: they encode themselves into a secureBuf instead
// of going through encoding/json.
type jsonAppender interface {
	appendJSON(buf *secureBuf) error
}
