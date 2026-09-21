package middleware

import (
	"net/http"
	"net/url"
	"strings"

	log "github.com/sirupsen/logrus"
)

const consoleTicketCookieName = "console-ticket"

// ConsoleWebSocketAuth prepares console WebSocket upgrade requests for console-proxy.
//
// Browsers cannot set Authorization on WebSocket, so the UI stores the ticket in a
// cookie. console-proxy prefers Authorization over the cookie and validates Origin
// for cookie-only auth. This middleware runs on the trusted UI proxy only:
//   - Reject requests whose Origin does not match the public UI origin. SameSite=Strict
//     still allows same-site cross-origin requests, so a hostile sibling origin could
//     otherwise ride the ticket cookie here and have Origin stripped for it below.
//   - Promote console-ticket cookie to Authorization: Bearer <ticket>
//   - Clear Origin so console-proxy uses bearer-ticket auth (no CSWSH Origin gate)
//
// baseUIURL is the public base URL of the UI (config.BaseUIURL); when empty, the
// request's own Host is used as the expected origin.
//
// Do not compose with Auth middleware, which would replace the ticket with the OIDC
// access token.
func ConsoleWebSocketAuth(baseUIURL string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !isTrustedOrigin(r, baseUIURL) {
				log.Warn("console WebSocket request rejected: origin not allowed")
				http.Error(w, "origin not allowed", http.StatusForbidden)
				return
			}

			r.Header.Del("Authorization")

			if cookie, err := r.Cookie(consoleTicketCookieName); err == nil {
				if ticket := strings.TrimSpace(cookie.Value); ticket != "" {
					r.Header.Set("Authorization", "Bearer "+ticket)
				}
			}

			r.Header.Del("Origin")
			r.Header.Del("Referer")

			next.ServeHTTP(w, r)
		})
	}
}

// isTrustedOrigin reports whether the request's Origin header matches the public UI
// origin. Browsers always send Origin on WebSocket upgrades, so an absent or
// mismatched Origin is rejected rather than silently proxied.
//
// When baseUIURL is configured, both scheme and host must match it — otherwise a
// plain-HTTP same-host page could pass as the configured HTTPS public origin. A
// non-empty baseUIURL that fails to parse is a startup misconfiguration, not an
// unset value, so it is rejected outright rather than silently falling back to the
// weaker host-only check.
// When baseUIURL is empty, only the request's own Host is compared: this proxy
// always terminates plain HTTP (TLS is terminated upstream by the ingress/Route,
// see docs/deployment-openshift-guide.md), so r.TLS is never a reliable signal of
// the scheme the browser actually used — comparing against it would reject every
// real HTTPS deployment that leaves BASE_UI_URL unset.
func isTrustedOrigin(r *http.Request, baseUIURL string) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return false
	}
	originURL, err := url.Parse(origin)
	if err != nil || originURL.Host == "" {
		return false
	}

	if baseUIURL == "" {
		return strings.EqualFold(originURL.Host, r.Host)
	}

	base, err := url.Parse(baseUIURL)
	if err != nil || base.Scheme == "" || base.Host == "" {
		return false
	}

	return strings.EqualFold(originURL.Scheme, base.Scheme) &&
		strings.EqualFold(originURL.Hostname(), base.Hostname()) &&
		effectivePort(originURL) == effectivePort(base)
}

// effectivePort returns u's explicit port, or the scheme's default port (so
// "https://host" and "https://host:443" compare equal, matching browser
// same-origin semantics instead of raw Host string comparison).
func effectivePort(u *url.URL) string {
	if port := u.Port(); port != "" {
		return port
	}
	if strings.EqualFold(u.Scheme, "http") {
		return "80"
	}
	if strings.EqualFold(u.Scheme, "https") {
		return "443"
	}
	return ""
}
