// Package authzn abstracts the authorization engine behind a vendor-
// neutral interface. Apps depend on the AuthZN interface; concrete
// adapters (SpiceDB today, AWS Cedar / OPA / etc. later) live alongside it.
//
// Per Fix-after-07 §A.4 (audit finding F-APP-3), the authzen-facade and
// any future authorizing service stops calling SpiceDB's gRPC API
// directly and instead consumes the AuthZN interface. The whole point
// of the AuthZEN façade is vendor-neutral at the API edge; this
// package extends that vendor-neutrality through the implementation
// layer.
package authzn

import "context"

// Subject identifies who is acting. Type is the high-level category
// ("user" | "service"); ID is a stable identifier opaque to this package.
type Subject struct {
	Type string
	ID   string
}

// Resource identifies what is being acted upon. Type is the resource
// kind ("document" | "tenant" | etc.); ID is a stable identifier.
type Resource struct {
	Type string
	ID   string
}

// Decision is the authorization outcome. Allowed is the binary verdict.
// Reason is optional, intended for audit logs (callers SHOULD log it
// regardless of Allowed) — it must NOT leak details that would help an
// attacker probe the policy graph (avoid "user X has direct relation
// Y on resource Z but lacks transitive Q"; prefer "permission denied"
// or implementation-internal trace IDs).
type Decision struct {
	Allowed bool
	Reason  string
}

// AuthZN is the abstract authorization engine. Implementations are
// constructed via adapter-specific factory functions (e.g.
// NewSpiceDBAuthZN). Apps hold a reference to the interface, never to
// a concrete type.
type AuthZN interface {
	// Evaluate returns a Decision for the (subject, action, resource)
	// triple. The action is a string from the application's vocabulary
	// (e.g. "read", "write", "admin"); the adapter maps it to whatever
	// the underlying engine expects.
	//
	// Implementations MUST NOT log subject/resource ID values verbatim
	// (these may be tenant-isolated user identifiers). Audit logging
	// of decisions is the caller's responsibility, with appropriate
	// hashing or redaction per the audit-log schema.
	Evaluate(ctx context.Context, subject Subject, action string, resource Resource) (*Decision, error)

	// Health performs an adapter-defined liveness check that exercises
	// the network path to the engine. Used by /readyz handlers as a
	// real integration probe rather than "the process is up." Each
	// adapter chooses the cheapest call that proves connectivity +
	// auth (SpiceDB: ReadSchema; OPA: GET /health; Cedar: verify the
	// policy bundle parses).
	//
	// Returns nil on success; any error means the engine is not usable
	// right now. Callers MAY pass a short timeout via the context.
	Health(ctx context.Context) error
}
