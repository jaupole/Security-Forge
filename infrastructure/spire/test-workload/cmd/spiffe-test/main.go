// Phase 2.5 — workload identity sanity check.
//
// This program is a smoke test for SPIRE in the local cluster. It runs as a
// pod with the spiffe.io/spire-managed-identity=true label, with the SPIFFE
// CSI driver volume mounted at /spiffe-workload-api. It then:
//
//   1. Connects to the SPIFFE Workload API socket.
//   2. Fetches its own X.509-SVID. Prints the SPIFFE ID, validity window, and
//      the CN of the issuer (which should be the SecForge upstream root).
//   3. Verifies the leaf SVID's chain back to the trust bundle the agent
//      provided.
//   4. Fetches a JWT-SVID with audience "test-audience" and prints both the
//      token and the parsed claims.
//   5. Sleeps 30 seconds (so the operator can re-exec into the CSI mount and
//      verify the on-disk material) then exits.
//
// See docs/01-architecture/06-workload-identity.md.
package main

import (
	"context"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/svid/jwtsvid"
	"github.com/spiffe/go-spiffe/v2/svid/x509svid"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
)

const (
	socketPath  = "unix:///spiffe-workload-api/spire-agent.sock"
	jwtAudience = "test-audience"
)

func main() {
	log.SetFlags(0)
	log.SetPrefix("[spiffe-test] ")

	// 90s is enough for SPIRE's controller-manager to reconcile a fresh
	// pod's UID into a registration on first start (typically ~20-40s on
	// this cluster). Any real workload should use go-spiffe's auto-source
	// helpers; this test does the same.
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	client, err := workloadapi.New(ctx, workloadapi.WithAddr(socketPath))
	if err != nil {
		log.Fatalf("connect Workload API: %v", err)
	}
	defer client.Close()

	// 1+2: X.509-SVID — retry through SPIRE's registration-propagation
	// window. The Workload API returns PermissionDenied when there's no
	// matching entry yet.
	var svid *x509svid.SVID
	deadline := time.Now().Add(90 * time.Second)
	for {
		svid, err = client.FetchX509SVID(ctx)
		if err == nil {
			break
		}
		if time.Now().After(deadline) {
			log.Fatalf("FetchX509SVID (after retries): %v", err)
		}
		fmt.Printf("waiting for SPIFFE identity... (%v)\n", err)
		time.Sleep(5 * time.Second)
	}
	leaf := svid.Certificates[0]
	fmt.Printf("X.509-SVID:\n")
	fmt.Printf("  SPIFFE ID:       %s\n", svid.ID)
	fmt.Printf("  Subject CN:      %s\n", leaf.Subject.CommonName)
	fmt.Printf("  Serial:          %s\n", leaf.SerialNumber)
	fmt.Printf("  Not before:      %s\n", leaf.NotBefore.Format(time.RFC3339))
	fmt.Printf("  Not after:       %s\n", leaf.NotAfter.Format(time.RFC3339))
	fmt.Printf("  Chain length:    %d\n", len(svid.Certificates))
	if len(svid.Certificates) > 1 {
		intermediate := svid.Certificates[len(svid.Certificates)-1]
		fmt.Printf("  Top-of-chain CN: %s\n", intermediate.Issuer.CommonName)
	}

	// 3: chain validation against the bundle the agent has
	bundles, err := client.FetchX509Bundles(ctx)
	if err != nil {
		log.Fatalf("FetchX509Bundles: %v", err)
	}
	td := svid.ID.TrustDomain()
	bundle, err := bundles.GetX509BundleForTrustDomain(td)
	if err != nil {
		log.Fatalf("trust bundle for %s: %v", td, err)
	}
	roots := x509.NewCertPool()
	for _, c := range bundle.X509Authorities() {
		roots.AddCert(c)
	}
	intermediates := x509.NewCertPool()
	for _, c := range svid.Certificates[1:] {
		intermediates.AddCert(c)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: roots, Intermediates: intermediates}); err != nil {
		log.Fatalf("chain verify FAILED: %v", err)
	}
	fmt.Printf("  Chain verified:  yes (against %d trust bundle root(s))\n", len(bundle.X509Authorities()))
	fmt.Printf("  Trust bundle root subjects:\n")
	for _, root := range bundle.X509Authorities() {
		fmt.Printf("    - %s\n", root.Subject.String())
	}

	// 4: JWT-SVID
	jwt, err := client.FetchJWTSVID(ctx, jwtsvidParams(svid.ID))
	if err != nil {
		log.Fatalf("FetchJWTSVID: %v", err)
	}
	fmt.Printf("\nJWT-SVID:\n")
	fmt.Printf("  SPIFFE ID:       %s\n", jwt.ID)
	fmt.Printf("  Audience:        %s\n", strings.Join(jwt.Audience, ","))
	fmt.Printf("  Expires at:      %s\n", jwt.Expiry.Format(time.RFC3339))
	fmt.Printf("  Token (head):    %s...\n", truncate(jwt.Marshal(), 60))
	if claims := decodeJWTClaims(jwt.Marshal()); claims != "" {
		fmt.Printf("  Claims:          %s\n", claims)
	}

	fmt.Printf("\nAll checks PASSED. Sleeping 30s for the operator to inspect the CSI mount...\n")
	select {
	case <-time.After(30 * time.Second):
	case <-ctx.Done():
	}
	fmt.Printf("Done.\n")
}

func jwtsvidParams(id spiffeid.ID) jwtsvid.Params {
	return jwtsvid.Params{
		Audience: jwtAudience,
		Subject:  id,
	}
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// decodeJWTClaims pulls out the payload of the JWT for human-readable output.
// We trust SPIRE; this is just for display.
func decodeJWTClaims(token string) string {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return ""
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ""
	}
	var claims map[string]any
	if err := json.Unmarshal(payload, &claims); err != nil {
		return ""
	}
	out, err := json.MarshalIndent(claims, "                   ", "  ")
	if err != nil {
		return ""
	}
	return string(out)
}

var _ = os.Args // silence unused-import in case we drop a feature
