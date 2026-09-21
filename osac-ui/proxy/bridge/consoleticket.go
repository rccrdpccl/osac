package bridge

import (
	"bytes"
	"encoding/json"
	"mime"
	"net/http"

	log "github.com/sirupsen/logrus"

	"github.com/osac/proxy/auth"
	"github.com/osac/proxy/config"
)

// bufferedResponse captures a handler's response so it can be inspected and rewritten
// before reaching the real ResponseWriter. net/http/httptest.ResponseRecorder is a
// testing utility and must not be used in production code, hence this minimal
// hand-rolled equivalent (just the http.ResponseWriter methods this file needs, plus
// http.Flusher — the wrapped Connect JSON handler requires its ResponseWriter to
// support it, and httptest.ResponseRecorder happened to satisfy that too).
type bufferedResponse struct {
	header     http.Header
	body       bytes.Buffer
	statusCode int
}

// Compile-time check that bufferedResponse keeps satisfying every interface a handler
// wrapped by WrapConsoleSessionCreate might type-assert its ResponseWriter against.
var (
	_ http.ResponseWriter = (*bufferedResponse)(nil)
	_ http.Flusher        = (*bufferedResponse)(nil)
)

func newBufferedResponse() *bufferedResponse {
	return &bufferedResponse{header: make(http.Header), statusCode: http.StatusOK}
}

func (b *bufferedResponse) Header() http.Header { return b.header }

func (b *bufferedResponse) Write(p []byte) (int, error) { return b.body.Write(p) }

func (b *bufferedResponse) WriteHeader(statusCode int) { b.statusCode = statusCode }

// Flush is a no-op: everything is buffered in memory and only reaches the real
// ResponseWriter once the wrapped handler returns (see WrapConsoleSessionCreate), so
// there is nothing to flush early. It exists only to satisfy http.Flusher.
func (b *bufferedResponse) Flush() {}

// ConsoleTicketCookieName is the cookie carrying the console session ticket.
// Must match consoleTicketCookieName in middleware/consolews.go, which reads
// it back and promotes it to Authorization for the WebSocket upgrade.
const ConsoleTicketCookieName = "console-ticket"

// ConsoleTicketCookiePath scopes the cookie to the console-sessions API, so
// the browser only ever sends it to endpoints that need it.
const ConsoleTicketCookiePath = "/api/fulfillment/v1/console_sessions"

// WrapConsoleSessionCreate rewrites the ConsoleSessions.Create response so the
// ticket travels to the browser only as an HttpOnly cookie, never in the JSON
// body. Cookies set via document.cookie in the browser can never be HttpOnly —
// only a Set-Cookie response header can do that — so this must happen here,
// not in the frontend. Mount this only on the exact Create route; it does not
// re-check path or method itself.
func WrapConsoleSessionCreate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := newBufferedResponse()
		next.ServeHTTP(rec, r)

		ticket, rewrittenBody, ok := extractAndStripTicket(rec)
		if !ok {
			copyRecordedResponse(w, rec)
			return
		}

		// Copy upstream headers before setting the ticket cookie: http.SetCookie
		// appends to Set-Cookie, but this loop's header[k] = v overwrites — if it
		// ran after and upstream ever sent its own Set-Cookie, it would silently
		// replace the ticket cookie and the browser would never receive it.
		header := w.Header()
		for k, v := range rec.Header() {
			header[k] = v
		}
		header.Del("Content-Length")
		http.SetCookie(w, &http.Cookie{
			Name:     ConsoleTicketCookieName,
			Value:    ticket,
			Path:     ConsoleTicketCookiePath,
			HttpOnly: true,
			Secure:   auth.IsSecure(r, config.BaseUIURL),
			SameSite: http.SameSiteStrictMode,
		})
		w.WriteHeader(rec.statusCode)
		if _, err := w.Write(rewrittenBody); err != nil {
			log.WithError(err).Warn("failed to write console session ticket response")
		}
	})
}

// extractAndStripTicket returns the ticket and a copy of the response body
// with "ticket" removed from the object payload, when the recorded response
// is a successful JSON ConsoleSessionsCreateResponse carrying a ticket. ok is
// false for anything else (errors, non-JSON, missing ticket) — callers must
// pass the response through unchanged in that case.
func extractAndStripTicket(rec *bufferedResponse) (ticket string, body []byte, ok bool) {
	if rec.statusCode != http.StatusOK {
		return "", nil, false
	}
	mediaType, _, err := mime.ParseMediaType(rec.Header().Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		return "", nil, false
	}

	var payload struct {
		Object map[string]any `json:"object"`
	}
	if err := json.Unmarshal(rec.body.Bytes(), &payload); err != nil || payload.Object == nil {
		return "", nil, false
	}

	rawTicket, hasTicket := payload.Object["ticket"].(string)
	if !hasTicket || rawTicket == "" {
		return "", nil, false
	}

	delete(payload.Object, "ticket")
	rewritten, err := json.Marshal(payload)
	if err != nil {
		return "", nil, false
	}

	return rawTicket, rewritten, true
}

func copyRecordedResponse(w http.ResponseWriter, rec *bufferedResponse) {
	header := w.Header()
	for k, v := range rec.Header() {
		header[k] = v
	}
	w.WriteHeader(rec.statusCode)
	if _, err := w.Write(rec.body.Bytes()); err != nil {
		log.WithError(err).Warn("failed to write console session response")
	}
}

// NewClearConsoleTicketCookieHandler returns a handler that deletes the
// console-ticket cookie by responding with an already-expired Set-Cookie for
// it. It performs no upstream call — an HttpOnly cookie can no longer be
// deleted via document.cookie once set server-side, so the frontend calls
// this endpoint instead wherever it used to clear the cookie directly. Safe
// to leave unauthenticated: it can only delete a cookie the caller can
// neither read nor use, so it grants nothing.
func NewClearConsoleTicketCookieHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		http.SetCookie(w, &http.Cookie{
			Name:     ConsoleTicketCookieName,
			Value:    "",
			Path:     ConsoleTicketCookiePath,
			MaxAge:   -1,
			HttpOnly: true,
			Secure:   auth.IsSecure(r, config.BaseUIURL),
			SameSite: http.SameSiteStrictMode,
		})
		w.WriteHeader(http.StatusNoContent)
	}
}
