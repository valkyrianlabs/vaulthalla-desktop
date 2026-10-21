package backup

import (
	"errors"
	"strings"
	"unicode/utf8"

	"github.com/1password/onepassword-sdk-go"
)

// Error is a protocol error: a stable code the app switches on, a message, and for 1Password failures a hint the
// app can show the user. Detail is the redacted text of the underlying error, for diagnostics.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Hint    string `json:"hint,omitempty"`
	Detail  string `json:"detail,omitempty"`
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

// Stable error codes. The Swift client mirrors this list (HelperErrorCode).
const (
	// Protocol and request errors.
	CodeBadRequest  = "bad_request"
	CodeUnknownOp   = "unknown_op"
	CodeLineTooLong = "line_too_long"
	CodeNoSession   = "no_session"
	CodeInternal    = "internal"

	// 1Password connection and authorization.
	CodeIntegrationDisabled = "integration_disabled"
	CodeAppNotRunning       = "app_not_running"
	CodeAppNotInstalled     = "app_not_installed"
	CodeLibraryBlocked      = "library_blocked"
	CodeUnsupportedBuild    = "unsupported_build"
	CodeLocked              = "locked"
	CodeDenied              = "denied"
	CodeAccountNotFound     = "account_not_found"
	CodeAccountSwitch       = "account_switch"
	CodeSessionExpired      = "session_expired"
	CodeRateLimited         = "rate_limited"
	CodeOnePassword         = "onepassword_error"

	// Item rules.
	CodeNotFound               = "not_found"
	CodeAmbiguousVault         = "ambiguous_vault"
	CodeDuplicateItem          = "duplicate_item"
	CodeVersionConflict        = "version_conflict"
	CodeConcurrentModification = "concurrent_modification"
	CodeVerifyFailed           = "verify_failed"
	// A key doesn't match its key check (a wrong or damaged key, or a check for another vault or version).
	CodeKeyCheckMismatch = "key_check_mismatch"
)

func newError(code, message string) *Error { return &Error{Code: code, Message: message} }

// hints are user-facing; the app may show them verbatim.
var hints = map[string]string{
	CodeIntegrationDisabled:    "In 1Password, open Settings → Developer and turn on “Integrate with other apps”.",
	CodeAppNotRunning:          "Open the 1Password app and sign in, and make sure Settings → Developer → “Integrate with other apps” is on.",
	CodeAppNotInstalled:        "Install the 1Password app for Mac in /Applications and sign in to your account.",
	CodeLibraryBlocked:         "This build of the helper can't load 1Password's integration library. It must be signed with the hardened-runtime entitlement com.apple.security.cs.disable-library-validation.",
	CodeUnsupportedBuild:       "This build of the helper was compiled without CGO, which 1Password's desktop integration requires.",
	CodeLocked:                 "Unlock 1Password and try again.",
	CodeDenied:                 "The request was declined in 1Password. Try again and approve it with Touch ID or your account password.",
	CodeAccountNotFound:        "Use the account name exactly as it appears at the top of 1Password's sidebar, or the account's ID.",
	CodeAccountSwitch:          "The helper is bound to another 1Password account; restart it to use a different one.",
	CodeSessionExpired:         "The 1Password session expired. Try again.",
	CodeRateLimited:            "1Password is rate-limiting requests. Wait a minute and try again.",
	CodeConcurrentModification: "The item changed in 1Password while syncing. Sync again.",
	CodeVersionConflict:        "1Password already holds a different key under this version. Nothing was changed; check the item before syncing again.",
	CodeKeyCheckMismatch:       "The key doesn't match its key check, so it isn't the vault's key. Nothing was written.",
}

func withHint(e *Error) *Error {
	if e.Hint == "" {
		e.Hint = hints[e.Code]
	}
	return e
}

// classify maps an SDK error to a stable code. The desktop-integration messages come from 1Password's Go SDK
// v0.4.1 (internal/shared_lib_core.go: return codes -3 "channel is closed" and -7 "unexpectedly dropped",
// "1Password desktop application not found", dlopen's "failed to open library"; client_builder_no_cgo.go: the
// CGO requirement; errors.go: DesktopSessionExpired, RateLimitExceeded). Locked and denied come from the
// 1Password app itself in wording the SDK doesn't publish, so they're matched on keywords; anything unrecognized
// stays onepassword_error rather than guessing.
func classify(err error) string {
	var expired *onepassword.DesktopSessionExpiredError
	if errors.As(err, &expired) {
		return CodeSessionExpired
	}
	var limited *onepassword.RateLimitExceededError
	if errors.As(err, &limited) {
		return CodeRateLimited
	}
	m := strings.ToLower(err.Error())
	has := func(words ...string) bool {
		for _, w := range words {
			if strings.Contains(m, w) {
				return true
			}
		}
		return false
	}
	switch {
	case has("channel is closed"):
		return CodeIntegrationDisabled
	case has("unexpectedly dropped"):
		return CodeAppNotRunning
	case has("desktop application not found"):
		return CodeAppNotInstalled
	case has("failed to open library", "failed to load send_message", "failed to load free_message"):
		return CodeLibraryBlocked
	case has("requires cgo"):
		return CodeUnsupportedBuild
	case has("rate limit"):
		return CodeRateLimited
	case has("incorrect item version"):
		return CodeConcurrentModification
	case has("denied", "declined", "cancelled", "canceled", "not authorized", "unauthorized", "right permissions"):
		return CodeDenied
	case strings.Contains(strings.ReplaceAll(m, "unlocked", ""), "locked"):
		return CodeLocked
	case has("account") && has("not found", "no such", "unknown", "does not exist", "doesn't exist"):
		return CodeAccountNotFound
	case has("not found"):
		return CodeNotFound
	}
	return CodeOnePassword
}

// mapError turns any error from a handler into a protocol Error, scrubbing secrets out of the detail text.
func mapError(err error, r *Redactor) *Error {
	var pe *Error
	if errors.As(err, &pe) {
		return withHint(pe)
	}
	code := classify(err)
	e := &Error{Code: code, Message: messages[code], Detail: truncate(r.scrub(err.Error()), 300)}
	if e.Message == "" {
		e.Message = "1Password reported an error"
	}
	return withHint(e)
}

var messages = map[string]string{
	CodeIntegrationDisabled:    "1Password's integration with other apps is turned off",
	CodeAppNotRunning:          "the 1Password app isn't running or dropped the connection",
	CodeAppNotInstalled:        "the 1Password app isn't installed",
	CodeLibraryBlocked:         "1Password's integration library couldn't be loaded",
	CodeUnsupportedBuild:       "desktop integration isn't available in this build",
	CodeLocked:                 "1Password is locked",
	CodeDenied:                 "1Password declined the request",
	CodeAccountNotFound:        "that 1Password account wasn't found",
	CodeSessionExpired:         "the 1Password session expired",
	CodeRateLimited:            "1Password is rate-limiting requests",
	CodeConcurrentModification: "the item changed in 1Password during the update",
	CodeNotFound:               "not found in 1Password",
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	cut := n
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + "…"
}

// Redactor scrubs known secret strings (base64 key values seen while handling a request) out of text that
// leaves the helper: error details and stderr.
type Redactor struct {
	secrets []string
}

func (r *Redactor) add(s string) {
	if r != nil && len(s) >= 8 {
		r.secrets = append(r.secrets, s)
	}
}

func (r *Redactor) scrub(s string) string {
	if r == nil {
		return s
	}
	for _, secret := range r.secrets {
		s = strings.ReplaceAll(s, secret, "[redacted]")
	}
	return s
}
