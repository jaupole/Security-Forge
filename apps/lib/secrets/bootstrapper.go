// Package secrets abstracts per-app secret-store bootstrap behind a
// vendor-neutral interface. Apps depend on the SecretBootstrapper
// interface; concrete adapters (OpenBao today, AWS Secrets Manager /
// Vault Enterprise / GCP Secret Manager later) live alongside it.
//
// Per Fix-after-07 §A.3 (audit finding F-APP-4) and ADR-0019, the BFF
// stops calling OpenBao's HTTP API directly and instead consumes the
// SecretBootstrapper interface. Compliance-cutover migrations land a
// second adapter rather than rewriting the BFF's bootstrap path.
//
// Scope: this interface is for STARTUP / LONG-LIVED-CACHE bootstrap of
// per-app credentials (the BFF's private_key_jwt PEM). Phase 6b-2's
// outbound third-party API credentials (Stripe / OpenAI / etc.) will
// extend this package — see PLAN.md Phase 6b-2 — but the SecretBootstrapper
// interface itself stays the same shape; refresh-aware helpers will be
// additional methods or a sibling type.
package secrets

import "context"

// SecretBootstrapper is the abstract secret store. Implementations hold
// the connection details and per-app role binding, and expose two reads:
//   - GetClientKey: the per-app private_key_jwt key bytes (PEM-encoded
//     RSA private key today; constructor-configured path).
//   - GetKV: a generic KV read for any path the bound role can read.
//
// Implementations MUST NOT log secret values. Errors include enough
// context for triage but never the value itself. Callers MUST treat
// returned bytes as sensitive and avoid persisting them anywhere
// except in-memory for the duration the app needs them.
type SecretBootstrapper interface {
	// GetClientKey returns the BFF's private_key_jwt PEM bytes. The
	// concrete adapter knows the path (constructor-configured); apps
	// don't pass paths to this method to keep configuration centralized.
	GetClientKey(ctx context.Context) ([]byte, error)

	// GetKV returns the value at the given path. The path is adapter-
	// specific (OpenBao: KV-v2 path like "secret/data/...";
	// AWS Secrets Manager: ARN; etc.). Callers that need cross-vendor
	// portability should obtain the path from configuration too, not
	// hardcode it.
	GetKV(ctx context.Context, path string) ([]byte, error)
}
