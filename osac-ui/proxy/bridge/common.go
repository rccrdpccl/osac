package bridge

import (
	"crypto/tls"
	"crypto/x509"
	"os"

	log "github.com/sirupsen/logrus"

	"github.com/osac/proxy/config"
)

// GetOIDCTlsConfig returns a TLS config for outbound OIDC requests (discovery, token exchange).
// It respects OIDC_TLS_INSECURE for dev environments with self-signed IdP certificates.
func GetOIDCTlsConfig() (*tls.Config, error) {
	tlsConfig := &tls.Config{
		MinVersion: tls.VersionTLS13,
	}

	if config.OIDCTlsInsecure {
		log.Warn("OIDC_TLS_INSECURE: TLS verification disabled for OIDC IdP (dev only)")
		tlsConfig.InsecureSkipVerify = true //nolint:gosec
		return tlsConfig, nil
	}

	caFile := config.OIDCTlsCaFile
	if caFile == "" {
		return tlsConfig, nil
	}

	caCert, err := os.ReadFile(caFile)
	if err != nil {
		return nil, err
	}

	caCertPool, err := x509.SystemCertPool()
	if err != nil {
		return nil, err
	}
	caCertPool.AppendCertsFromPEM(caCert)
	tlsConfig.RootCAs = caCertPool

	return tlsConfig, nil
}

// GetTlsConfig returns a TLS config for outbound Fulfillment requests.
// It respects FULFILLMENT_TLS_INSECURE for dev environments with self-signed certificates.
func GetTlsConfig() (*tls.Config, error) {
	tlsConfig := &tls.Config{
		MinVersion: tls.VersionTLS13,
	}

	// OSAC_WORKAROUND_REMOVE(tls-insecure): dev-only; remove when all targets use proper CA trust.
	if config.FulfillmentTlsInsecure {
		log.Warn("FULFILLMENT_TLS_INSECURE: TLS verification disabled for upstream (dev only)")
		tlsConfig.InsecureSkipVerify = true //nolint:gosec
	}

	caFile := config.FulfillmentTlsCaFile
	if caFile == "" {
		return tlsConfig, nil
	}

	caCert, err := os.ReadFile(caFile)
	if err != nil {
		return nil, err
	}

	caCertPool, err := x509.SystemCertPool()
	if err != nil {
		return nil, err
	}
	caCertPool.AppendCertsFromPEM(caCert)
	tlsConfig.RootCAs = caCertPool

	return tlsConfig, nil
}
