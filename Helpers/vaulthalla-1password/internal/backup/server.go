// Package backup is the helper's core: the JSON-lines protocol, the item layout, and the version rules that keep
// every key version needed for restoration. It talks to 1Password only through store.Backend.
//
// Protocol: one JSON object per line on stdin, one response line per request on stdout, in order.
//
//	→ {"id": 1, "op": "item.upsert", "params": {...}}
//	← {"id": 1, "ok": true, "result": {...}}
//	← {"id": 1, "ok": false, "error": {"code": "version_conflict", "message": "...", "hint": "..."}}
//
// A line that can't be parsed (or is longer than MaxLine) gets a response with "id": null. The server returns
// when stdin closes.
package backup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"time"

	"github.com/vaulthalla/desktop/helpers/vaulthalla-1password/internal/store"
)

// Handler handles one op. raw aliases the request line, which is wiped after the response is written. Secrets the
// handler sees go into r so error details are scrubbed of them.
type Handler func(ctx context.Context, raw []byte, r *Redactor) (any, error)

const DefaultMaxLine = 1 << 20 // 1 MiB: room for ~1000 key versions

type Server struct {
	Connector store.Connector
	MaxLine   int
	Log       io.Writer // redacted diagnostics only (stderr)
	Now       func() time.Time
	// Extra adds ops (the fake build's fault injection). Release builds leave it nil.
	Extra map[string]Handler

	backend      store.Backend
	boundAccount string
}

func (s *Server) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Server) handler(op string) (Handler, bool) {
	switch op {
	case "account.check":
		return s.accountCheck, true
	case "vault.ensure":
		return s.vaultEnsure, true
	case "items.list":
		return s.itemsList, true
	case "item.upsert":
		return s.itemUpsert, true
	case "item.reveal":
		return s.itemReveal, true
	}
	h, ok := s.Extra[op]
	return h, ok
}

func (s *Server) logf(format string, args ...any) {
	if s.Log != nil {
		fmt.Fprintf(s.Log, "vaulthalla-1password: "+format+"\n", args...)
	}
}

// Serve answers requests from in on out until in reaches EOF.
func (s *Server) Serve(ctx context.Context, in io.Reader, out io.Writer) error {
	max := s.MaxLine
	if max <= 0 {
		max = DefaultMaxLine
	}
	lr := &lineReader{r: in, chunk: make([]byte, 64<<10), max: max}
	defer wipe(lr.chunk)
	for {
		line, tooLong, err := lr.next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		var resp *secureBuf
		if tooLong {
			s.logf("rejected a request line longer than %d bytes", max)
			resp = errorResponse(nil, newError(CodeLineTooLong, fmt.Sprintf("request line exceeds %d bytes", max)))
		} else {
			trimmed := bytes.TrimSpace(line.bytes())
			if len(trimmed) == 0 {
				line.wipe()
				continue
			}
			resp = s.handleLine(ctx, trimmed)
			line.wipe()
		}
		_, werr := out.Write(resp.bytes())
		resp.wipe()
		if werr != nil {
			return werr
		}
	}
}

type envelope struct {
	ID     rawAlias `json:"id"`
	Op     string   `json:"op"`
	Params rawAlias `json:"params"`
}

var safeID = regexp.MustCompile(`^(-?[0-9]{1,19}|"[A-Za-z0-9._:-]{1,64}")$`)

// handleLine runs one request and returns its response line (with the trailing newline). The caller writes it
// and wipes it.
func (s *Server) handleLine(ctx context.Context, line []byte) *secureBuf {
	var env envelope
	if err := strictUnmarshal(line, &env); err != nil {
		s.logf("rejected a malformed request line")
		return errorResponse(nil, newError(CodeBadRequest, "malformed request: "+sanitizeJSONError(err)))
	}
	if !safeID.Match(env.ID) {
		s.logf("rejected a request without a valid id")
		return errorResponse(nil, newError(CodeBadRequest, "id must be a number or a short string"))
	}
	id := append([]byte(nil), env.ID...) // not secret; outlives the line
	h, ok := s.handler(env.Op)
	if !ok {
		s.logf("id=%s unknown op", id)
		return errorResponse(id, newError(CodeUnknownOp, "unknown op"))
	}

	start := time.Now()
	r := &Redactor{}
	result, err := h(ctx, env.Params, r)
	elapsed := time.Since(start).Milliseconds()
	if err != nil {
		pe := mapError(err, r)
		s.logf("id=%s op=%s error=%s %dms", id, env.Op, pe.Code, elapsed)
		return errorResponse(id, pe)
	}
	if rr, ok := result.(*RevealResult); ok {
		defer rr.wipe()
	}
	resp, encErr := okResponse(id, result)
	if encErr != nil {
		s.logf("id=%s op=%s error=internal (encoding)", id, env.Op)
		return errorResponse(id, newError(CodeInternal, "couldn't encode the result"))
	}
	s.logf("id=%s op=%s ok %dms", id, env.Op, elapsed)
	return resp
}

func writeID(buf *secureBuf, id []byte) {
	buf.writeString(`{"id":`)
	if id == nil {
		buf.writeString("null")
	} else {
		buf.write(id)
	}
}

func okResponse(id []byte, result any) (*secureBuf, error) {
	buf := newSecureBuf(4096)
	writeID(buf, id)
	buf.writeString(`,"ok":true,"result":`)
	var err error
	if a, ok := result.(jsonAppender); ok {
		err = a.appendJSON(buf)
	} else {
		err = buf.writeJSON(result)
	}
	if err != nil {
		buf.wipe()
		return nil, err
	}
	buf.writeString("}\n")
	return buf, nil
}

func errorResponse(id []byte, e *Error) *secureBuf {
	buf := newSecureBuf(512)
	writeID(buf, id)
	buf.writeString(`,"ok":false,"error":`)
	data, _ := json.Marshal(withHint(e))
	buf.write(data)
	buf.writeString("}\n")
	return buf
}

// lineReader splits a stream into lines using buffers it owns and wipes (bufio keeps copies it never clears).
type lineReader struct {
	r          io.Reader
	chunk      []byte
	start, end int
	max        int
	eof        bool
}

// next returns the next line (without its newline) in a buffer the caller wipes, or tooLong if the line exceeded
// max (its bytes are discarded up to the next newline). io.EOF once the input is exhausted.
func (lr *lineReader) next() (*secureBuf, bool, error) {
	line := newSecureBuf(4096)
	discard := false
	add := func(seg []byte) {
		if discard {
			return
		}
		if len(line.b)+len(seg) > lr.max {
			discard = true
			line.wipe()
			return
		}
		line.write(seg)
	}
	for {
		if lr.start < lr.end {
			pending := lr.chunk[lr.start:lr.end]
			if i := bytes.IndexByte(pending, '\n'); i >= 0 {
				add(pending[:i])
				wipe(pending[:i+1])
				lr.start += i + 1
				if discard {
					return nil, true, nil
				}
				return line, false, nil
			}
			add(pending)
			wipe(pending)
			lr.start, lr.end = 0, 0
		}
		if lr.eof {
			switch {
			case discard:
				return nil, true, nil
			case len(line.b) > 0: // a last line without a newline
				return line, false, nil
			}
			return nil, false, io.EOF
		}
		n, err := lr.r.Read(lr.chunk)
		lr.start, lr.end = 0, n
		if errors.Is(err, io.EOF) {
			lr.eof = true
		} else if err != nil {
			line.wipe()
			return nil, false, err
		}
	}
}
