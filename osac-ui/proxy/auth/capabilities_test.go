package auth

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestFetchIssuerURL_Success(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
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

	issuer, err := FetchIssuerURL(srv.URL, srv.Client())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if issuer != "https://keycloak.example.com/realms/osac" {
		t.Fatalf("got issuer %q, want %q", issuer, "https://keycloak.example.com/realms/osac")
	}
}

func TestFetchIssuerURL_RetriesOnEOF(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		n := calls.Add(1)
		if n == 1 {
			hj, ok := w.(http.Hijacker)
			if !ok {
				t.Fatal("server does not support hijacking")
			}
			conn, _, err := hj.Hijack()
			if err != nil {
				t.Fatalf("hijack failed: %v", err)
			}
			conn.Close()
			return
		}
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

	issuer, err := FetchIssuerURL(srv.URL, srv.Client())
	if err != nil {
		t.Fatalf("expected retry to succeed, got error: %v", err)
	}
	if issuer != "https://keycloak.example.com/realms/osac" {
		t.Fatalf("got issuer %q, want %q", issuer, "https://keycloak.example.com/realms/osac")
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("expected 2 calls (1 fail + 1 retry), got %d", got)
	}
}

func TestFetchIssuerURL_NoRetryOnNonTransientError(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	_, err := FetchIssuerURL(srv.URL, srv.Client())
	if err == nil {
		t.Fatal("expected error for 500 response")
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("expected 1 call (no retry for non-transient error), got %d", got)
	}
}

func TestFetchIssuerURL_NoIssuers(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(capabilitiesResponse{})
	}))
	defer srv.Close()

	_, err := FetchIssuerURL(srv.URL, srv.Client())
	if err == nil {
		t.Fatal("expected error for empty issuers")
	}
	if !strings.Contains(err.Error(), "no trusted token issuers") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestIsTransientConnError(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"bare EOF", io.EOF, true},
		{"wrapped EOF", fmt.Errorf("fetch capabilities: %w", io.EOF), true},
		{"net.OpError", &net.OpError{Op: "read", Err: io.EOF}, true},
		{"EOF in message", fmt.Errorf("connection closed: EOF"), true},
		{"connection reset", fmt.Errorf("read: connection reset by peer"), true},
		{"non-transient", fmt.Errorf("capabilities endpoint returned HTTP 500"), false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := isTransientConnError(tc.err)
			if got != tc.want {
				t.Errorf("isTransientConnError(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}
