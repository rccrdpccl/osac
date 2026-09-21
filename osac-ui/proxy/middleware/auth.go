package middleware

import (
	"net/http"

	"github.com/osac/proxy/auth"
)

// Auth reads the session cookie, looks up the server-side session, and injects an
// Authorization: Bearer header into the request before it is forwarded to the upstream
// fulfillment API. The access token is used (not the ID token) because Authorino's OPA
// policy relies on realm_access.roles and other claims only present in the access token.
// If no valid session is found, the request is forwarded as-is (upstream returns 401).
func Auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Header.Del("Authorization")
		tokenData := auth.LookupSessionCookies(r)
		if tokenData != nil && tokenData.AccessToken != "" {
			r.Header.Set("Authorization", "Bearer "+tokenData.AccessToken)
		}
		next.ServeHTTP(w, r)
	})
}
