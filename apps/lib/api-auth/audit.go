package apiauth

import (
	"errors"
	"net/http"
)

// Audit emits one structured JSON log line per hop in a SecForge call chain,
// per the SPIFFE+request-id schema fixed in ADR-0012 § Q4 and surfaced in
// ADR-0014 § Library API surface. Backed by a caller-supplied io.Writer
// (typically os.Stdout — Promtail picks it up to Loki).
type Audit struct {
	cfg AuditConfig
}

// NewAudit returns an Audit. The constructor performs no I/O.
func NewAudit(cfg AuditConfig) *Audit {
	return &Audit{cfg: cfg}
}

// LogHop emits a single audit line for one hop in a call chain.
//
// hopIndex is 0 for the inbound edge (BFF receiving from browser), 1 for
// the next outbound call, and so on. callerWorkloadID is the SPIFFE-SVID
// of the immediate caller; callerUserSub is the originating user's `sub`
// (same value across the entire chain). targetAudience is the audience
// the next hop's token is being minted for. status is the HTTP status the
// hop produced.
//
// Returns a non-nil error if the audit-log write fails (caller policy
// decides whether to fail the request or proceed without the log). On
// timeout, the line is dropped and ErrAuditTimeout-like behavior is
// reported via the returned error.
//
// Implementation lands in commit 4 of Phase 6b-1.
func (a *Audit) LogHop(req *http.Request, hopIndex int, callerWorkloadID, callerUserSub, targetAudience string, status int) error {
	return errors.New("apiauth: LogHop not yet implemented (skeleton)")
}
