package auth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	log "github.com/sirupsen/logrus"
)

type capabilitiesResponse struct {
	Authn struct {
		TrustedTokenIssuers []string `json:"trusted_token_issuers"`
	} `json:"authn"`
}

// FetchIssuerURL fetches the fulfillment capabilities and returns the first
// trusted OIDC issuer URL. It retries once on transient connection errors
// (EOF, connection reset) that indicate a stale keep-alive connection.
func FetchIssuerURL(fulfillmentAPIURL string, httpClient *http.Client) (string, error) {
	if httpClient == nil {
		httpClient = http.DefaultClient
	}

	capabilitiesURL := strings.TrimSuffix(fulfillmentAPIURL, "/") + "/api/fulfillment/v1/capabilities"

	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		issuer, err := fetchIssuerOnce(capabilitiesURL, httpClient)
		if err == nil {
			return issuer, nil
		}
		lastErr = err
		if attempt == 0 && isTransientConnError(err) {
			log.WithError(err).Warn("transient connection error fetching capabilities, retrying")
			continue
		}
		break
	}
	return "", lastErr
}

func fetchIssuerOnce(capabilitiesURL string, httpClient *http.Client) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, capabilitiesURL, nil)
	if err != nil {
		return "", fmt.Errorf("build capabilities request: %w", err)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("fetch capabilities: %w", err)
	}
	defer func() {
		if err := resp.Body.Close(); err != nil {
			log.WithError(err).Warn("failed to close response body")
		}
	}()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("capabilities endpoint returned HTTP %d", resp.StatusCode)
	}
	var caps capabilitiesResponse
	if err := json.NewDecoder(resp.Body).Decode(&caps); err != nil {
		return "", fmt.Errorf("decode capabilities: %w", err)
	}
	if len(caps.Authn.TrustedTokenIssuers) == 0 {
		return "", fmt.Errorf("no trusted token issuers in capabilities response")
	}
	return caps.Authn.TrustedTokenIssuers[0], nil
}

// isTransientConnError returns true for errors caused by stale pooled
// connections: EOF, connection reset, or broken pipe.
func isTransientConnError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, io.EOF) {
		return true
	}
	var netErr *net.OpError
	if errors.As(err, &netErr) {
		return true
	}
	msg := err.Error()
	return strings.Contains(msg, "EOF") ||
		strings.Contains(msg, "connection reset") ||
		strings.Contains(msg, "broken pipe")
}
