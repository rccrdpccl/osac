package auth

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestLookupSessionCookiesRequiresAccess(t *testing.T) {
	t.Parallel()

	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/", nil)
	req.AddCookie(&http.Cookie{Name: refreshTokenCookieName, Value: "refresh-only"})
	if got := LookupSessionCookies(req); got != nil {
		t.Fatalf("expected nil without access cookie, got %+v", got)
	}

	req.AddCookie(&http.Cookie{Name: accessTokenCookieName, Value: "access"})
	got := LookupSessionCookies(req)
	if got == nil || got.AccessToken != "access" || got.RefreshToken != "refresh-only" {
		t.Fatalf("unexpected session cookies: %+v", got)
	}
}

func TestLookupRefreshCookiesAllowsRefreshOnly(t *testing.T) {
	t.Parallel()

	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/", nil)
	req.AddCookie(&http.Cookie{Name: refreshTokenCookieName, Value: "refresh-only"})
	got := LookupRefreshCookies(req)
	if got == nil || got.RefreshToken != "refresh-only" {
		t.Fatalf("expected refresh-only lookup, got %+v", got)
	}
	if got.AccessToken != "" {
		t.Fatalf("expected empty access token, got %q", got.AccessToken)
	}
}
