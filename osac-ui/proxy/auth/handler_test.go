package auth

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestHandler_IssuerURLCachesResult(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(capabilitiesResponse{
			Authn: struct {
				TrustedTokenIssuers []string `json:"trusted_token_issuers"`
			}{
				TrustedTokenIssuers: []string{"https://keycloak.example.com/realms/osac"},
			},
		})
	}))
	defer srv.Close()

	h := &Handler{
		FulfillmentAPIURL:     srv.URL,
		FulfillmentHTTPClient: srv.Client(),
	}

	issuer1, err := h.issuerURL()
	if err != nil {
		t.Fatalf("first call: %v", err)
	}
	issuer2, err := h.issuerURL()
	if err != nil {
		t.Fatalf("second call: %v", err)
	}

	if issuer1 != issuer2 {
		t.Fatalf("issuer mismatch: %q vs %q", issuer1, issuer2)
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("expected 1 upstream call (cached), got %d", got)
	}
}

func TestHandler_IssuerURLRefetchesAfterExpiry(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(capabilitiesResponse{
			Authn: struct {
				TrustedTokenIssuers []string `json:"trusted_token_issuers"`
			}{
				TrustedTokenIssuers: []string{"https://keycloak.example.com/realms/osac"},
			},
		})
	}))
	defer srv.Close()

	h := &Handler{
		FulfillmentAPIURL:     srv.URL,
		FulfillmentHTTPClient: srv.Client(),
	}

	_, err := h.issuerURL()
	if err != nil {
		t.Fatalf("first call: %v", err)
	}

	// Force cache expiry.
	h.issuerMu.Lock()
	h.issuerExpires = time.Now().Add(-1 * time.Second)
	h.issuerMu.Unlock()

	_, err = h.issuerURL()
	if err != nil {
		t.Fatalf("second call after expiry: %v", err)
	}

	if got := calls.Load(); got != 2 {
		t.Fatalf("expected 2 upstream calls (cache expired), got %d", got)
	}
}

// TestGetLoginRefreshRefreshOnlyCookie covers the path exercised after the short-lived
// access cookie has expired but the refresh cookie is still valid: LookupRefreshCookies
// must find the session from the refresh cookie alone, and the handler must reissue
// session cookies from the refreshed tokens.
func TestGetLoginRefreshRefreshOnlyCookie(t *testing.T) {
	t.Parallel()

	const oldRefreshToken = "old-refresh-token"
	const newAccessToken = "new-access-token"
	const newRefreshToken = "new-refresh-token"

	var issuer string
	mux := http.NewServeMux()
	mux.HandleFunc("/api/fulfillment/v1/capabilities", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"authn": map[string]any{"trusted_token_issuers": []string{issuer}},
		}); err != nil {
			t.Errorf("encode capabilities response: %v", err)
		}
	})
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(OIDCConfig{Issuer: issuer, TokenEndpoint: issuer + "/token"}); err != nil {
			t.Errorf("encode OIDC discovery response: %v", err)
		}
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Fatalf("parse token request form: %v", err)
		}
		if got := r.FormValue("grant_type"); got != "refresh_token" {
			t.Fatalf("grant_type = %q, want refresh_token", got)
		}
		if got := r.FormValue("refresh_token"); got != oldRefreshToken {
			t.Fatalf("refresh_token = %q, want %q", got, oldRefreshToken)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(TokenResponse{
			AccessToken:  newAccessToken,
			RefreshToken: newRefreshToken,
			ExpiresIn:    300,
		}); err != nil {
			t.Errorf("encode token response: %v", err)
		}
	})

	server := httptest.NewServer(mux)
	defer server.Close()
	issuer = server.URL

	h := &Handler{
		ClientID:              "test-client",
		FulfillmentAPIURL:     server.URL,
		FulfillmentHTTPClient: server.Client(),
		OIDCHTTPClient:        server.Client(),
	}

	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/api/login/refresh", nil)
	req.AddCookie(&http.Cookie{Name: refreshTokenCookieName, Value: oldRefreshToken})

	rec := httptest.NewRecorder()
	h.GetLoginRefresh(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body: %s", rec.Code, http.StatusOK, rec.Body.String())
	}

	var gotAccess, gotRefresh bool
	for _, c := range rec.Result().Cookies() {
		switch {
		case c.Name == accessTokenCookieName && c.Value == newAccessToken:
			gotAccess = true
		case c.Name == refreshTokenCookieName && c.Value == newRefreshToken:
			gotRefresh = true
		}
	}
	if !gotAccess {
		t.Fatalf("expected reissued access cookie %q, got %+v", newAccessToken, rec.Result().Cookies())
	}
	if !gotRefresh {
		t.Fatalf("expected reissued refresh cookie %q, got %+v", newRefreshToken, rec.Result().Cookies())
	}
}
