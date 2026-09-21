package auth

import (
	"net/url"
	"testing"
)

func TestBuildAuthorizeURL_IncludesOrganizationScope(t *testing.T) {
	cfg := &OIDCConfig{
		AuthorizationEndpoint: "https://keycloak.example.com/realms/osac/protocol/openid-connect/auth",
	}

	rawURL := BuildAuthorizeURL(cfg, "osac-ui", "https://app.example.com/api/login/callback", "test-state", "test-challenge")

	parsed, err := url.Parse(rawURL)
	if err != nil {
		t.Fatalf("failed to parse authorize URL: %v", err)
	}

	scope := parsed.Query().Get("scope")
	if scope == "" {
		t.Fatal("scope parameter missing from authorize URL")
	}

	wantScopes := []string{"openid", "organization"}
	for _, s := range wantScopes {
		found := false
		for _, got := range splitScopes(scope) {
			if got == s {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("scope %q not found in authorize URL scope=%q", s, scope)
		}
	}
}

func TestBuildAuthorizeURL_SetsAllRequiredParams(t *testing.T) {
	cfg := &OIDCConfig{
		AuthorizationEndpoint: "https://keycloak.example.com/auth",
	}

	rawURL := BuildAuthorizeURL(cfg, "my-client", "https://example.com/callback", "my-state", "my-challenge")

	parsed, err := url.Parse(rawURL)
	if err != nil {
		t.Fatalf("failed to parse authorize URL: %v", err)
	}

	q := parsed.Query()
	checks := map[string]string{
		"response_type":         "code",
		"client_id":             "my-client",
		"redirect_uri":          "https://example.com/callback",
		"state":                 "my-state",
		"code_challenge":        "my-challenge",
		"code_challenge_method": "S256",
	}

	for param, want := range checks {
		if got := q.Get(param); got != want {
			t.Errorf("param %q = %q, want %q", param, got, want)
		}
	}
}

func splitScopes(scope string) []string {
	var scopes []string
	current := ""
	for _, c := range scope {
		if c == ' ' {
			if current != "" {
				scopes = append(scopes, current)
				current = ""
			}
		} else {
			current += string(c)
		}
	}
	if current != "" {
		scopes = append(scopes, current)
	}
	return scopes
}
