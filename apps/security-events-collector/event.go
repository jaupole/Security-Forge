// Package main — security-events-collector wire types.
//
// Event schema is canonical per Phase 6b-2 prompt § Section 8 and ADR-0013
// § Multi-layer prevention guardrails. Every guardrail bypass — pre-commit,
// CI, Trivy, Kyverno, K8s Secret creation, library redaction failure, image-
// build hygiene — emits one of these to a single sink. Phase 7b wires
// Promtail / Loki on top of the JSON-line stream this collector writes.
package main

import (
	"errors"
	"fmt"
	"strings"
)

// Layer identifies which guardrail layer fired the event. Closed enum;
// payloads outside this set are rejected.
const (
	LayerKyverno           = "kyverno"
	LayerGitleaks          = "gitleaks"
	LayerTrivy             = "trivy"
	LayerPrecommit         = "precommit"
	LayerCI                = "ci"
	LayerKubernetesSecret  = "kubernetes-secret"
	LayerLibraryRedaction  = "library-redaction"
)

var validLayers = map[string]struct{}{
	LayerKyverno:          {},
	LayerGitleaks:         {},
	LayerTrivy:            {},
	LayerPrecommit:        {},
	LayerCI:               {},
	LayerKubernetesSecret: {},
	LayerLibraryRedaction: {},
}

// Severity classifies the event's importance. Closed enum.
const (
	SeverityWarn     = "warn"
	SeverityHigh     = "high"
	SeverityCritical = "critical"
)

var validSeverities = map[string]struct{}{
	SeverityWarn:     {},
	SeverityHigh:     {},
	SeverityCritical: {},
}

// Outcome captures what happened — denied admission, allowed via escape
// hatch, warn-only enforcement, or actual leak. Closed enum.
const (
	OutcomeBlocked         = "blocked"
	OutcomeAnnotatedBypass = "annotated-bypass"
	OutcomeWarnOnly        = "warn-only"
	OutcomeLeaked          = "leaked"
)

var validOutcomes = map[string]struct{}{
	OutcomeBlocked:         {},
	OutcomeAnnotatedBypass: {},
	OutcomeWarnOnly:        {},
	OutcomeLeaked:          {},
}

// Event is the canonical secrets.guardrail.bypass event. Field tags match
// the JSON schema in phase-06b-2-outbound-secrets.md § Section 8 verbatim;
// downstream Promtail / Loki / Grafana queries depend on this shape.
//
// `Event` is the JSON event-name discriminator and MUST equal
// `secrets.guardrail.bypass`. Anything else is rejected at validation time.
type Event struct {
	Timestamp     string `json:"ts"`
	EventName     string `json:"event"`
	Layer         string `json:"layer"`
	Severity      string `json:"severity"`
	Actor         string `json:"actor"`
	Resource      string `json:"resource"`
	Rule          string `json:"rule"`
	Outcome       string `json:"outcome"`
	AnnotationRef string `json:"annotation_ref,omitempty"`
	RequestID     string `json:"request_id,omitempty"`
}

// EventNameBypass is the only acceptable value for Event.EventName. Held as
// a constant to keep the schema-discriminator visible in one place.
const EventNameBypass = "secrets.guardrail.bypass"

// Validate enforces Section 8's schema constraints. Returns nil only when
// every required field is present, has a valid value, and the event-name
// discriminator matches. Per ADR-0013 § Defense in depth, validation
// failures are themselves loggable: callers may emit a synthetic
// `severity=high, outcome=leaked` event when this returns non-nil.
func (e *Event) Validate() error {
	if e == nil {
		return errors.New("event: nil")
	}
	if e.EventName != EventNameBypass {
		return fmt.Errorf("event: discriminator mismatch — got %q, want %q",
			e.EventName, EventNameBypass)
	}
	if e.Timestamp == "" {
		return errors.New("event: ts required")
	}
	if _, ok := validLayers[e.Layer]; !ok {
		return fmt.Errorf("event: layer %q not in closed enum", e.Layer)
	}
	if _, ok := validSeverities[e.Severity]; !ok {
		return fmt.Errorf("event: severity %q not in closed enum", e.Severity)
	}
	if _, ok := validOutcomes[e.Outcome]; !ok {
		return fmt.Errorf("event: outcome %q not in closed enum", e.Outcome)
	}
	if strings.TrimSpace(e.Resource) == "" {
		return errors.New("event: resource required")
	}
	if strings.TrimSpace(e.Rule) == "" {
		return errors.New("event: rule required")
	}
	return nil
}
