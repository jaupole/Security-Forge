package secrets

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func TestDynamicCredential_StringRedacts(t *testing.T) {
	c := &DynamicCredential{
		Username:      "v-app-readwrite-aaa",
		Password:      "super-secret-password",
		LeaseID:       "database/creds/proposal-forge-readwrite/abc123",
		LeaseDuration: 3600,
	}
	got := c.String()
	if !strings.Contains(got, "redacted") {
		t.Fatalf("String = %q, want redacted form", got)
	}
	if !strings.HasPrefix(got, "[") || !strings.HasSuffix(got, "]") {
		t.Fatalf("String = %q, want square-bracketed form (HTML-escape-safe)", got)
	}
	if strings.Contains(got, "super-secret-password") {
		t.Fatalf("String leaked password: %q", got)
	}
}

func TestDynamicCredential_MarshalJSONRedacts(t *testing.T) {
	c := &DynamicCredential{
		Username:      "v-app-readwrite-aaa",
		Password:      "leak-canary-pw",
		LeaseID:       "lease/abc",
		LeaseDuration: 60,
	}
	out, err := json.Marshal(c)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if strings.Contains(string(out), "leak-canary-pw") {
		t.Fatalf("JSON leaked password: %s", out)
	}
}

func TestDynamicCredential_DSN(t *testing.T) {
	c := &DynamicCredential{
		Username: "v-alice",
		Password: "pw",
	}
	got := c.DSN("postgres://{{.Username}}:{{.Password}}@db:5432/proposals")
	const want = "postgres://v-alice:pw@db:5432/proposals"
	if got != want {
		t.Fatalf("DSN = %q, want %q", got, want)
	}
}

func TestClient_GetDynamic_HappyPath(t *testing.T) {
	bs := &fakeOutboundBootstrapper{
		kv: map[string][]byte{
			"database/creds/proposal-forge-readwrite": []byte(`{
				"lease_id": "database/creds/proposal-forge-readwrite/abc",
				"lease_duration": 3600,
				"data": {
					"username": "v-app-aaa",
					"password": "pw-bbb"
				}
			}`),
		},
	}
	c, _ := New(bs, Config{AppName: "proposal-forge"})

	cred, err := c.GetDynamic(context.Background(), "readwrite")
	if err != nil {
		t.Fatalf("GetDynamic: %v", err)
	}
	if cred.Username != "v-app-aaa" {
		t.Fatalf("Username = %q", cred.Username)
	}
	if cred.Password != "pw-bbb" {
		t.Fatalf("Password = %q", cred.Password)
	}
	if cred.LeaseDuration != 3600 {
		t.Fatalf("LeaseDuration = %d", cred.LeaseDuration)
	}
}

func TestClient_GetDynamic_EmptyRole(t *testing.T) {
	bs := &fakeOutboundBootstrapper{}
	c, _ := New(bs, Config{AppName: "x"})
	if _, err := c.GetDynamic(context.Background(), ""); err == nil {
		t.Fatalf("empty role must error")
	}
}

func TestClient_GetDynamic_MissingFields(t *testing.T) {
	bs := &fakeOutboundBootstrapper{
		kv: map[string][]byte{
			"database/creds/x-r": []byte(`{"lease_id":"l","lease_duration":60,"data":{}}`),
		},
	}
	c, _ := New(bs, Config{AppName: "x"})

	_, err := c.GetDynamic(context.Background(), "r")
	if err == nil {
		t.Fatalf("missing username/password must error")
	}
}
