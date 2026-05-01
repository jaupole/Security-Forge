package authzn

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"os"

	v1 "github.com/authzed/authzed-go/proto/authzed/api/v1"
	authzed "github.com/authzed/authzed-go/v1"
	"github.com/authzed/grpcutil"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

// SpiceDBAuthZN is the SpiceDB adapter for AuthZN. It speaks the SpiceDB
// gRPC API behind the vendor-neutral interface; callers see only AuthZN.
//
// Construct via NewSpiceDBAuthZN. Concrete struct is unexported; the
// constructor returns the AuthZN interface.
type SpiceDBAuthZN struct {
	client *authzed.Client
}

// NewSpiceDBAuthZN dials a SpiceDB endpoint over mTLS using the provided
// CA bundle for server-cert verification + a pre-shared key for
// authentication.
//
// Arguments:
//   - endpoint:     "host:port" gRPC address (no scheme)
//   - presharedKey: the SpiceDB API key (rotates per Phase 4 / 7d plan)
//   - tlsCAPath:    file path to a PEM CA bundle that signs the SpiceDB
//                   server cert; the cluster-internal certs use the
//                   in-cluster issuer
//
// Returns a constructed AuthZN. Failures during dial are returned;
// per-request failures surface from Evaluate.
func NewSpiceDBAuthZN(endpoint, presharedKey, tlsCAPath string) (AuthZN, error) {
	if endpoint == "" {
		return nil, errors.New("endpoint required")
	}
	if presharedKey == "" {
		return nil, errors.New("presharedKey required")
	}
	if tlsCAPath == "" {
		return nil, errors.New("tlsCAPath required")
	}
	tlsCfg, err := tlsConfigFromCA(tlsCAPath)
	if err != nil {
		return nil, fmt.Errorf("build TLS config: %w", err)
	}
	client, err := authzed.NewClient(
		endpoint,
		grpc.WithTransportCredentials(credentials.NewTLS(tlsCfg)),
		grpcutil.WithBearerToken(presharedKey),
	)
	if err != nil {
		return nil, fmt.Errorf("dial spicedb at %s: %w", endpoint, err)
	}
	return &SpiceDBAuthZN{client: client}, nil
}

// Evaluate translates the AuthZN call into SpiceDB CheckPermission with
// minimize_latency consistency. Implementation matches the previous
// inline call site in authzen-facade/main.go (now removed by §A.6 wiring).
//
// The action string maps directly to SpiceDB's permission name. The
// (subject.Type, subject.ID) become a SubjectReference; (resource.Type,
// resource.ID) become an ObjectReference.
func (a *SpiceDBAuthZN) Evaluate(ctx context.Context, subject Subject, action string, resource Resource) (*Decision, error) {
	resp, err := a.client.CheckPermission(ctx, &v1.CheckPermissionRequest{
		Resource: &v1.ObjectReference{
			ObjectType: resource.Type,
			ObjectId:   resource.ID,
		},
		Permission: action,
		Subject: &v1.SubjectReference{
			Object: &v1.ObjectReference{
				ObjectType: subject.Type,
				ObjectId:   subject.ID,
			},
		},
		Consistency: &v1.Consistency{
			// minimize_latency is correct for the steady-state fast path.
			// Read-your-writes flows pass an explicit ZedToken via the
			// context; Phase 6b-1+ wiring will add ZedToken plumbing.
			Requirement: &v1.Consistency_MinimizeLatency{MinimizeLatency: true},
		},
	})
	if err != nil {
		return nil, err
	}
	allowed := resp.GetPermissionship() == v1.CheckPermissionResponse_PERMISSIONSHIP_HAS_PERMISSION
	return &Decision{Allowed: allowed}, nil
}

// Health calls SpiceDB's ReadSchema as a liveness probe. The schema
// fetch is sub-millisecond cached and exercises the gRPC + TLS + token
// path, so a successful round-trip proves the adapter can do work.
func (a *SpiceDBAuthZN) Health(ctx context.Context) error {
	_, err := a.client.ReadSchema(ctx, &v1.ReadSchemaRequest{})
	return err
}

// tlsConfigFromCA builds a TLS client config that trusts the supplied
// CA bundle. We do NOT skip verification.
func tlsConfigFromCA(caFile string) (*tls.Config, error) {
	caPEM, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("read ca: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, errors.New("ca pem contained no certs")
	}
	return &tls.Config{
		RootCAs:    pool,
		MinVersion: tls.VersionTLS13,
	}, nil
}
