package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestConsoleWebSocketAuth_promotesCookieAndClearsOrigin(t *testing.T) {
	t.Parallel()

	var captured *http.Request
	handler := ConsoleWebSocketAuth("http://localhost:5173")(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		copied := *r
		captured = &copied
	}))

	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/api/fulfillment/v1/console_sessions/connect", nil)
	req.AddCookie(&http.Cookie{Name: consoleTicketCookieName, Value: "console-jwt"})
	req.Header.Set("Authorization", "Bearer oidc-access-token")
	req.Header.Set("Origin", "http://localhost:5173")
	req.Header.Set("Referer", "http://localhost:5173/vms/vm-1")

	handler.ServeHTTP(httptest.NewRecorder(), req)

	if captured == nil {
		t.Fatal("expected downstream handler to run")
	}
	if got := captured.Header.Get("Authorization"); got != "Bearer console-jwt" {
		t.Fatalf("Authorization = %q, want Bearer console-jwt", got)
	}
	if captured.Header.Get("Origin") != "" {
		t.Fatalf("Origin = %q, want empty", captured.Header.Get("Origin"))
	}
	if captured.Header.Get("Referer") != "" {
		t.Fatalf("Referer = %q, want empty", captured.Header.Get("Referer"))
	}
}

func TestConsoleWebSocketAuth_leavesAuthorizationEmptyWithoutCookie(t *testing.T) {
	t.Parallel()

	var captured *http.Request
	handler := ConsoleWebSocketAuth("http://localhost:5173")(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		copied := *r
		captured = &copied
	}))

	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/api/fulfillment/v1/console_sessions/connect", nil)
	req.Header.Set("Authorization", "Bearer oidc-access-token")
	req.Header.Set("Origin", "http://localhost:5173")

	handler.ServeHTTP(httptest.NewRecorder(), req)

	if captured == nil {
		t.Fatal("expected downstream handler to run")
	}
	if captured.Header.Get("Authorization") != "" {
		t.Fatalf("Authorization = %q, want empty", captured.Header.Get("Authorization"))
	}
}

func TestConsoleWebSocketAuth_rejectsMissingOrigin(t *testing.T) {
	t.Parallel()

	var captured bool
	handler := ConsoleWebSocketAuth("http://localhost:5173")(http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		captured = true
	}))

	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/api/fulfillment/v1/console_sessions/connect", nil)
	req.AddCookie(&http.Cookie{Name: consoleTicketCookieName, Value: "console-jwt"})

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if captured {
		t.Fatal("expected downstream handler not to run without an Origin header")
	}
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusForbidden)
	}
}

func TestConsoleWebSocketAuth_rejectsMismatchedOrigin(t *testing.T) {
	t.Parallel()

	var captured bool
	handler := ConsoleWebSocketAuth("http://localhost:5173")(http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		captured = true
	}))

	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/api/fulfillment/v1/console_sessions/connect", nil)
	req.AddCookie(&http.Cookie{Name: consoleTicketCookieName, Value: "console-jwt"})
	req.Header.Set("Origin", "http://hostile.example.com")

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if captured {
		t.Fatal("expected downstream handler not to run with a mismatched Origin header")
	}
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusForbidden)
	}
}

func TestConsoleWebSocketAuth_fallsBackToRequestHostWhenBaseUIURLUnset(t *testing.T) {
	t.Parallel()

	var captured *http.Request
	handler := ConsoleWebSocketAuth("")(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		copied := *r
		captured = &copied
	}))

	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/api/fulfillment/v1/console_sessions/connect", nil)
	req.Host = "osac.example.com"
	// Scheme deliberately not checked in fallback mode: this proxy always
	// terminates plain HTTP (TLS ends upstream at the ingress), so r.TLS can't
	// tell us the scheme the browser actually used. An HTTPS Origin must still
	// be accepted when it matches the request Host.
	req.Header.Set("Origin", "https://osac.example.com")

	handler.ServeHTTP(httptest.NewRecorder(), req)

	if captured == nil {
		t.Fatal("expected downstream handler to run when Origin matches the request Host")
	}
}

func TestConsoleWebSocketAuth_rejectsWhenBaseUIURLIsMalformed(t *testing.T) {
	t.Parallel()

	var captured bool
	// A control character makes url.Parse fail outright; this is a startup
	// misconfiguration, not an unset baseUIURL, so it must fail closed rather
	// than fall back to the weaker host-only check.
	handler := ConsoleWebSocketAuth("http://\x7f")(http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		captured = true
	}))

	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/api/fulfillment/v1/console_sessions/connect", nil)
	req.AddCookie(&http.Cookie{Name: consoleTicketCookieName, Value: "console-jwt"})
	req.Host = "osac.example.com"
	req.Header.Set("Origin", "http://osac.example.com")

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if captured {
		t.Fatal("expected downstream handler not to run when baseUIURL is malformed")
	}
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusForbidden)
	}
}

func TestConsoleWebSocketAuth_treatsExplicitDefaultPortAsEquivalent(t *testing.T) {
	t.Parallel()

	var captured *http.Request
	// baseUIURL spells out the default HTTPS port explicitly; browsers never send an
	// Origin with a default port, so raw Host string comparison would reject every
	// real request if this weren't normalized.
	handler := ConsoleWebSocketAuth("https://osac.example.com:443")(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		copied := *r
		captured = &copied
	}))

	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/api/fulfillment/v1/console_sessions/connect", nil)
	req.AddCookie(&http.Cookie{Name: consoleTicketCookieName, Value: "console-jwt"})
	req.Header.Set("Origin", "https://osac.example.com")

	handler.ServeHTTP(httptest.NewRecorder(), req)

	if captured == nil {
		t.Fatal("expected downstream handler to run when Origin omits the default port baseUIURL spells out")
	}
}

func TestConsoleWebSocketAuth_rejectsSchemeMismatch(t *testing.T) {
	t.Parallel()

	var captured bool
	handler := ConsoleWebSocketAuth("https://localhost:5173")(http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		captured = true
	}))

	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/api/fulfillment/v1/console_sessions/connect", nil)
	req.AddCookie(&http.Cookie{Name: consoleTicketCookieName, Value: "console-jwt"})
	// Same host as baseUIURL, but plain HTTP instead of HTTPS — must not be trusted
	// as if it were the public HTTPS origin.
	req.Header.Set("Origin", "http://localhost:5173")

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if captured {
		t.Fatal("expected downstream handler not to run when Origin scheme does not match")
	}
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusForbidden)
	}
}
