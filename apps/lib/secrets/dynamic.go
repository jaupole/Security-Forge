package secrets

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// DynamicCredential is a leased database credential issued by OpenBao's
// database secrets engine at `database/creds/<app>-<role>` per
// ADR-0013 § 1. Username and Password are exposed as bare strings —
// they're typically passed straight into sql.Open's DSN, so a Secret
// wrapper would force every consumer through Use just to assemble the
// DSN. Redaction is enforced at logging boundaries via String and
// MarshalJSON, which never include the password.
//
// Lease cleanup: callers SHOULD treat LeaseDuration as the credential's
// hard expiry and arrange teardown accordingly. Explicit revocation
// (PUT /v1/sys/leases/revoke) requires a non-GET helper not yet on the
// SecretBootstrapper interface; revocation lands when the first real
// dynamic-cred consumer arrives in Phase 9+ and the interface gains a
// Post helper. Until then, lease expiry is the only cleanup path.
type DynamicCredential struct {
	Username      string
	Password      string
	LeaseID       string
	LeaseDuration int
}

// String returns a redacted representation; never includes the password.
// Uses square brackets so the marker survives json.Marshal's HTML escaping.
func (c *DynamicCredential) String() string {
	if c == nil {
		return "[nil dynamic credential]"
	}
	return fmt.Sprintf("[redacted dynamic credential lease=%s ttl=%ds]", c.LeaseID, c.LeaseDuration)
}

// MarshalJSON returns the redacted string form so accidental JSON
// serialization in a log line / Sentry payload doesn't leak the password.
func (c *DynamicCredential) MarshalJSON() ([]byte, error) {
	return []byte(fmt.Sprintf(`"%s"`, c.String())), nil
}

// DSN substitutes "{{.Username}}" and "{{.Password}}" in template,
// replacing the first occurrence of each. Useful for assembling
// "postgres://{{.Username}}:{{.Password}}@host:5432/db?sslmode=verify-full".
func (c *DynamicCredential) DSN(template string) string {
	s := strings.Replace(template, "{{.Username}}", c.Username, 1)
	s = strings.Replace(s, "{{.Password}}", c.Password, 1)
	return s
}

// GetDynamic reads `database/creds/<AppName>-<role>` and returns a
// DynamicCredential. The path is templated per ADR-0013 § 4 so the
// OpenBao role's policy authorizes only this app's role prefix.
func (c *Client) GetDynamic(ctx context.Context, role string) (*DynamicCredential, error) {
	if role == "" {
		return nil, errors.New("role required")
	}
	path := fmt.Sprintf("database/creds/%s-%s", c.appName, role)
	raw, err := c.bs.GetKV(ctx, path)
	if err != nil {
		return nil, fmt.Errorf("openbao read role=%s: %w", role, err)
	}
	var r struct {
		LeaseID       string `json:"lease_id"`
		LeaseDuration int    `json:"lease_duration"`
		Data          struct {
			Username string `json:"username"`
			Password string `json:"password"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		return nil, fmt.Errorf("decode dynamic credential role=%s: %w", role, err)
	}
	if r.Data.Username == "" || r.Data.Password == "" {
		return nil, fmt.Errorf("dynamic credential missing username/password role=%s", role)
	}
	return &DynamicCredential{
		Username:      r.Data.Username,
		Password:      r.Data.Password,
		LeaseID:       r.LeaseID,
		LeaseDuration: r.LeaseDuration,
	}, nil
}
