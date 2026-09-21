package bridge

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/osac/proxy/config"
)

func jsonHandler(t *testing.T, status int, contentType, body string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if contentType != "" {
			w.Header().Set("Content-Type", contentType)
		}
		w.WriteHeader(status)
		if _, err := w.Write([]byte(body)); err != nil {
			t.Fatalf("failed to write synthetic response: %v", err)
		}
	})
}

func TestWrapConsoleSessionCreate_setsHttpOnlyCookieAndStripsTicket(t *testing.T) {
	t.Parallel()

	inner := jsonHandler(t, http.StatusOK, "application/json",
		`{"object":{"resourceType":"CONSOLE_RESOURCE_TYPE_COMPUTE_INSTANCE","ticket":"secret-ticket"}}`)

	handler := WrapConsoleSessionCreate(inner)

	req := httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/osac.public.v1.ConsoleSessions/Create", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}

	cookies := rec.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatalf("expected exactly one cookie, got %d", len(cookies))
	}
	cookie := cookies[0]
	if cookie.Name != ConsoleTicketCookieName {
		t.Fatalf("expected cookie name %q, got %q", ConsoleTicketCookieName, cookie.Name)
	}
	if cookie.Value != "secret-ticket" {
		t.Fatalf("expected cookie value %q, got %q", "secret-ticket", cookie.Value)
	}
	if !cookie.HttpOnly {
		t.Fatal("expected cookie to be HttpOnly")
	}
	if cookie.SameSite != http.SameSiteStrictMode {
		t.Fatalf("expected SameSite=Strict, got %v", cookie.SameSite)
	}
	if cookie.Path != ConsoleTicketCookiePath {
		t.Fatalf("expected cookie path %q, got %q", ConsoleTicketCookiePath, cookie.Path)
	}
	if cookie.Secure {
		t.Fatal("expected cookie not to be Secure over plain HTTP")
	}

	if strings.Contains(rec.Body.String(), "secret-ticket") {
		t.Fatalf("expected ticket to be stripped from response body, got %q", rec.Body.String())
	}

	var payload struct {
		Object map[string]any `json:"object"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("failed to unmarshal rewritten body: %v", err)
	}
	if _, hasTicket := payload.Object["ticket"]; hasTicket {
		t.Fatal("expected ticket field to be removed from body")
	}
	if payload.Object["resourceType"] != "CONSOLE_RESOURCE_TYPE_COMPUTE_INSTANCE" {
		t.Fatal("expected other fields to be preserved")
	}
}

func TestWrapConsoleSessionCreate_stripsTicketWithMixedCaseContentType(t *testing.T) {
	t.Parallel()

	inner := jsonHandler(t, http.StatusOK, "Application/JSON; charset=UTF-8",
		`{"object":{"ticket":"secret-ticket"}}`)
	handler := WrapConsoleSessionCreate(inner)

	req := httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/osac.public.v1.ConsoleSessions/Create", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	cookies := rec.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Value != "secret-ticket" {
		t.Fatal("expected ticket to be stripped and cookie set for a mixed-case JSON content type")
	}
	if strings.Contains(rec.Body.String(), "secret-ticket") {
		t.Fatalf("expected ticket to be stripped from response body, got %q", rec.Body.String())
	}
}

func TestWrapConsoleSessionCreate_preservesTicketCookieAlongsideUpstreamSetCookie(t *testing.T) {
	t.Parallel()

	inner := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		http.SetCookie(w, &http.Cookie{Name: "upstream-cookie", Value: "upstream-value"})
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"object":{"ticket":"secret-ticket"}}`))
	})
	handler := WrapConsoleSessionCreate(inner)

	req := httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/osac.public.v1.ConsoleSessions/Create", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	cookies := rec.Result().Cookies()
	if len(cookies) != 2 {
		t.Fatalf("expected both the upstream cookie and the ticket cookie, got %d: %v", len(cookies), cookies)
	}
	var sawUpstream, sawTicket bool
	for _, c := range cookies {
		switch c.Name {
		case "upstream-cookie":
			sawUpstream = c.Value == "upstream-value"
		case ConsoleTicketCookieName:
			sawTicket = c.Value == "secret-ticket"
		}
	}
	if !sawUpstream {
		t.Fatal("expected the upstream Set-Cookie to pass through unchanged")
	}
	if !sawTicket {
		t.Fatal("expected the ticket cookie to still be set, not clobbered by the upstream Set-Cookie")
	}
}

func TestWrapConsoleSessionCreate_marksSecureOverHTTPS(t *testing.T) {
	// Not t.Parallel(): mutates the package-level config.BaseUIURL that
	// auth.IsSecure reads, which the other (parallel) tests in this file also
	// read indirectly. Non-parallel tests run to completion before any
	// t.Parallel() test in this package starts, so this is race-free as long
	// as it stays serial.
	original := config.BaseUIURL
	config.BaseUIURL = "https://console.example.com"
	t.Cleanup(func() { config.BaseUIURL = original })

	inner := jsonHandler(t, http.StatusOK, "application/json", `{"object":{"ticket":"secret-ticket"}}`)
	handler := WrapConsoleSessionCreate(inner)

	req := httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/osac.public.v1.ConsoleSessions/Create", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	cookies := rec.Result().Cookies()
	if len(cookies) != 1 || !cookies[0].Secure {
		t.Fatal("expected cookie to be Secure when baseUIURL is https")
	}
}

func TestWrapConsoleSessionCreate_passesThroughOnError(t *testing.T) {
	t.Parallel()

	inner := jsonHandler(t, http.StatusUnauthorized, "application/json", `{"code":"unauthenticated"}`)
	handler := WrapConsoleSessionCreate(inner)

	req := httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/osac.public.v1.ConsoleSessions/Create", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected status %d, got %d", http.StatusUnauthorized, rec.Code)
	}
	if len(rec.Result().Cookies()) != 0 {
		t.Fatal("expected no cookie to be set on an error response")
	}
	if rec.Body.String() != `{"code":"unauthenticated"}` {
		t.Fatalf("expected error body to pass through unchanged, got %q", rec.Body.String())
	}
}

func TestWrapConsoleSessionCreate_passesThroughWhenNoTicket(t *testing.T) {
	t.Parallel()

	body := `{"object":{"resourceType":"CONSOLE_RESOURCE_TYPE_COMPUTE_INSTANCE"}}`
	inner := jsonHandler(t, http.StatusOK, "application/json", body)
	handler := WrapConsoleSessionCreate(inner)

	req := httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/osac.public.v1.ConsoleSessions/Create", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if len(rec.Result().Cookies()) != 0 {
		t.Fatal("expected no cookie to be set when the response has no ticket")
	}
	if rec.Body.String() != body {
		t.Fatalf("expected body to pass through unchanged, got %q", rec.Body.String())
	}
}

func TestNewClearConsoleTicketCookieHandler(t *testing.T) {
	t.Parallel()

	handler := NewClearConsoleTicketCookieHandler()

	req := httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/api/console-ticket/clear", nil)
	rec := httptest.NewRecorder()
	handler(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected status %d, got %d", http.StatusNoContent, rec.Code)
	}

	cookies := rec.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatalf("expected exactly one cookie, got %d", len(cookies))
	}
	cookie := cookies[0]
	if cookie.Name != ConsoleTicketCookieName {
		t.Fatalf("expected cookie name %q, got %q", ConsoleTicketCookieName, cookie.Name)
	}
	if cookie.MaxAge >= 0 {
		t.Fatalf("expected an expiring cookie (negative MaxAge), got %d", cookie.MaxAge)
	}
	if !cookie.HttpOnly {
		t.Fatal("expected cleared cookie to still be HttpOnly")
	}
	if cookie.Path != ConsoleTicketCookiePath {
		t.Fatalf("expected cookie path %q, got %q", ConsoleTicketCookiePath, cookie.Path)
	}
}
