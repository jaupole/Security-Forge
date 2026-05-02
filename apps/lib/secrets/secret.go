package secrets

import (
	"encoding/base64"
	"errors"
	"strings"
)

// Secret wraps secret bytes with redaction-aware String and MarshalJSON
// so accidental fmt/log/json serialization prints "<redacted>" rather
// than the value. Callers access the underlying bytes via Use.
//
// Per ADR-0013 § 7 (Hardened mode + runtime hygiene): the underlying
// byte slice is best-effort zeroed after Use returns. Go's GC makes
// this imperfect — the original allocation may be copied during scans —
// but the intent is to reduce the in-memory residency window and
// prevent long-lived references from outliving Use's scope.
type Secret struct {
	value []byte
}

// NewSecret wraps val. The provided slice is taken by reference;
// callers MUST NOT retain the slice after construction. Used by
// Client.GetField and by tests.
func NewSecret(val []byte) Secret {
	return Secret{value: val}
}

// String returns the redaction marker. Always. Uses square brackets
// rather than angle brackets so json.Marshal (which HTML-escapes < and
// > in MarshalJSON output by default) doesn't print "<redacted>"
// in JSON contexts.
func (s Secret) String() string { return "[redacted]" }

// MarshalJSON returns a JSON-encoded redaction marker. Always.
func (s Secret) MarshalJSON() ([]byte, error) {
	return []byte(`"[redacted]"`), nil
}

// IsZero reports whether the secret is uninitialized or already-Used.
// Use sets the underlying slice to nil after zeroing its bytes, so
// IsZero is the post-Use indicator.
func (s Secret) IsZero() bool { return len(s.value) == 0 }

// Use invokes fn with the underlying secret bytes, then best-effort
// zeroes the bytes AND nils the slice header so the Secret's value is
// no longer reachable through this receiver. fn MUST NOT retain b —
// any retained reference points at zeroed memory after Use returns.
//
// Pointer receiver so the slice nil-out propagates to the caller's
// Secret variable (Go auto-addresses local Secret values, so callers
// don't need to pre-take an address).
//
// If fn is nil or the secret is empty/already-used, Use returns an
// error without invoking fn.
func (s *Secret) Use(fn func(b []byte) error) error {
	if fn == nil {
		return errors.New("secrets.Secret.Use: nil callback")
	}
	if len(s.value) == 0 {
		return errors.New("secrets.Secret.Use: secret is empty or already used")
	}
	err := fn(s.value)
	for i := range s.value {
		s.value[i] = 0
	}
	s.value = nil
	return err
}

// HTTPHeader returns ("Authorization", scheme+" "+secret) for direct
// passing to http.Header.Set. Internally uses Use, so the secret is
// zeroed after the header value is constructed. Per ADR-0013 § 7 this
// is the preferred pattern over manual concatenation.
func (s *Secret) HTTPHeader(scheme string) (name, value string, err error) {
	err = s.Use(func(b []byte) error {
		value = scheme + " " + string(b)
		return nil
	})
	if err != nil {
		return "", "", err
	}
	return "Authorization", value, nil
}

// BasicAuth returns a Basic-auth header tuple ("Authorization",
// "Basic <base64(user:secret)>"). Mirrors net/http.Request.SetBasicAuth's
// header but accepts a Secret-wrapped password.
func (s *Secret) BasicAuth(username string) (name, value string, err error) {
	err = s.Use(func(b []byte) error {
		joined := username + ":" + string(b)
		value = "Basic " + base64.StdEncoding.EncodeToString([]byte(joined))
		return nil
	})
	if err != nil {
		return "", "", err
	}
	return "Authorization", value, nil
}

// DSN substitutes the first occurrence of "{{.Secret}}" in template
// with the secret value. Useful for postgres://user:{{.Secret}}@host/db
// patterns. The returned string is plain Go (NOT Secret-wrapped); the
// Hardened-mode invariant only protects values held in Secret.
func (s *Secret) DSN(template string) (string, error) {
	var out string
	err := s.Use(func(b []byte) error {
		out = strings.Replace(template, "{{.Secret}}", string(b), 1)
		return nil
	})
	if err != nil {
		return "", err
	}
	return out, nil
}
