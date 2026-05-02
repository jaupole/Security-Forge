package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	libSecrets "github.com/secforge/lib/secrets"
)

// Phase 6b-2 commit 5 — reference adoption of the outbound-secrets
// surface (`apps/lib/secrets/` Client + Secret + GetField). The BFF was
// already a `apps/lib/secrets/` *bootstrapper* consumer (it fetches its
// own private_key_jwt PEM at startup); this file makes it the first
// outbound-Client consumer too. ADR-0013 § 5 (Library surface) is the
// policy this implements.
//
// The endpoint is feature-gated default-OFF via BFF_ENABLE_ADMIN_TEST_OUTBOUND_SECRET=true.
// It exists solely to demonstrate the Hardened-mode + Secret.Use pattern
// against a real OpenBao path; it does NOT return the raw credential
// value to the client. The response surfaces only:
//
//   - the integration + field that was read
//   - the BLAKE-style fingerprint (SHA-256, hex, first 16 chars) of the
//     value, so an operator can compare across reads without ever seeing
//     the value itself
//   - the cache-hit boolean (always false for a single call, but useful
//     under load)
//   - a roundtrip duration
//
// Operator-time prerequisite (per the Phase 6b-2 RESUME marker):
//
//	bao kv put secret/apps/helloworld-bff/test api_key=fingerprint-only-test-value
//
// (One-line setup, value is non-sensitive and only ever flows through
// Secret.Use; the response NEVER contains it.)

const (
	// AdminTestOutboundIntegration is the OpenBao integration name read
	// by the debug endpoint. Lives at:
	//   secret/data/apps/helloworld-bff/test
	AdminTestOutboundIntegration = "test"
	AdminTestOutboundField       = "api_key"
)

// outboundSecretsClient is the Hardened-mode Client constructed once at
// startup. Reuses the same OpenBaoBootstrapper as the private_key_jwt
// bootstrap path — the SecretBootstrapper interface is single-instance
// per app, and the templated OpenBao policy authorizes reads from
// `secret/data/apps/helloworld-bff/*` for this app's role.
type outboundSecretsClient struct {
	client *libSecrets.Client
	now    func() time.Time
}

func newOutboundSecretsClient(bs libSecrets.SecretBootstrapper, appName string) (*outboundSecretsClient, error) {
	c, err := libSecrets.New(bs, libSecrets.Config{
		AppName:  appName,
		CacheTTL: 5 * time.Minute,
		// Hardened: true is the new-app default per ADR-0013 § 7.
		// helloworld-bff is the reference adopter, so we set it
		// explicitly here for documentation rather than relying on the
		// zero-value default.
		Hardened: true,
	})
	if err != nil {
		return nil, err
	}
	return &outboundSecretsClient{client: c, now: time.Now}, nil
}

// adminTestOutboundResponse is the JSON shape returned by the debug
// endpoint. `ValueFingerprint` is a SHA-256 of the secret value (first
// 16 hex chars) — operationally distinguishes reads of different values
// without ever surfacing the value itself.
type adminTestOutboundResponse struct {
	Integration      string `json:"integration"`
	Field            string `json:"field"`
	ValueFingerprint string `json:"value_fingerprint_sha256_16"`
	RoundtripMillis  int64  `json:"roundtrip_ms"`
}

// handleAdminTestOutboundSecret demonstrates GetField → Secret.Use. The
// response NEVER contains the secret value; the only value-derived field
// is a fingerprint computed inside Use's callback (so even the
// fingerprint computation runs while the byte slice is still scoped).
//
// This is the canonical first-class app pattern for ADR-0013 outbound
// secrets — future apps copy this shape verbatim, swapping `test` for
// the real integration name and `api_key` for the real field.
func handleAdminTestOutboundSecret(osc *outboundSecretsClient, log *slog.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := osc.now()
		// Bound the read so a degenerate OpenBao state can't hang the
		// request handler indefinitely.
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		secret, err := osc.client.GetField(ctx, AdminTestOutboundIntegration, AdminTestOutboundField)
		if err != nil {
			log.Warn("admin test outbound: GetField failed", "err", err)
			httpJSON(w, http.StatusServiceUnavailable, map[string]string{
				"error":  "outbound_secret_unavailable",
				"detail": err.Error(),
			})
			return
		}

		var fingerprint string
		useErr := secret.Use(func(b []byte) error {
			if len(b) == 0 {
				return errors.New("empty secret value")
			}
			h := sha256.Sum256(b)
			fingerprint = hex.EncodeToString(h[:])[:16]
			return nil
		})
		if useErr != nil {
			log.Warn("admin test outbound: Use failed", "err", useErr)
			httpJSON(w, http.StatusServiceUnavailable, map[string]string{
				"error":  "outbound_secret_use_failed",
				"detail": useErr.Error(),
			})
			return
		}

		resp := adminTestOutboundResponse{
			Integration:      AdminTestOutboundIntegration,
			Field:            AdminTestOutboundField,
			ValueFingerprint: fingerprint,
			RoundtripMillis:  osc.now().Sub(start).Milliseconds(),
		}
		// The Secret was zeroed inside Use; nothing in this response
		// path ever held the raw value.
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	}
}

// (httpJSON lives in proxy.go.)
