package main

import (
	"strings"
	"testing"
)

func TestEventValidate(t *testing.T) {
	t.Parallel()

	good := func() *Event {
		return &Event{
			Timestamp: "2026-05-02T14:00:00Z",
			EventName: EventNameBypass,
			Layer:     LayerKyverno,
			Severity:  SeverityHigh,
			Actor:     "spiffe://secforge.local/ns/app/sa/proposal-forge",
			Resource:  "Pod/default/proposal-forge-abc",
			Rule:      "no-secret-shaped-env-vars",
			Outcome:   OutcomeBlocked,
		}
	}

	cases := []struct {
		name    string
		mut     func(*Event)
		wantErr string
	}{
		{"happy", func(*Event) {}, ""},
		{"nil_event", nil, "nil"},
		{"missing_event_name", func(e *Event) { e.EventName = "" }, "discriminator"},
		{"wrong_event_name", func(e *Event) { e.EventName = "secrets.boom" }, "discriminator"},
		{"missing_ts", func(e *Event) { e.Timestamp = "" }, "ts required"},
		{"unknown_layer", func(e *Event) { e.Layer = "made-up" }, "layer"},
		{"unknown_severity", func(e *Event) { e.Severity = "panic" }, "severity"},
		{"unknown_outcome", func(e *Event) { e.Outcome = "vibes" }, "outcome"},
		{"missing_resource", func(e *Event) { e.Resource = "  " }, "resource required"},
		{"missing_rule", func(e *Event) { e.Rule = "" }, "rule required"},
		{"all_outcomes", func(e *Event) { e.Outcome = OutcomeAnnotatedBypass }, ""},
		{"warn_severity", func(e *Event) { e.Severity = SeverityWarn }, ""},
		{"all_layers_precommit", func(e *Event) { e.Layer = LayerPrecommit }, ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var e *Event
			if tc.name == "nil_event" {
				e = nil
			} else {
				e = good()
				tc.mut(e)
			}
			err := e.Validate()
			switch {
			case tc.wantErr == "" && err != nil:
				t.Fatalf("unexpected err: %v", err)
			case tc.wantErr != "" && err == nil:
				t.Fatalf("want err containing %q, got nil", tc.wantErr)
			case tc.wantErr != "" && !strings.Contains(err.Error(), tc.wantErr):
				t.Fatalf("err %q missing %q", err.Error(), tc.wantErr)
			}
		})
	}
}
