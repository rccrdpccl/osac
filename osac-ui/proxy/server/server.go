package server

import (
	"bytes"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// SpaHandler handler that serves SPA assets
type SpaHandler struct {
	Dir string
}

// ServeHTTP serves HTTP requests with the contents of the file system
func (h SpaHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := filepath.Join(h.Dir, filepath.Clean("/"+r.URL.Path))
	fi, err := os.Stat(path)
	if os.IsNotExist(err) || (err == nil && fi.IsDir()) {
		h.serveIndex(w, r)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.FileServer(http.Dir(h.Dir)).ServeHTTP(w, r)
}

func (h SpaHandler) serveIndex(w http.ResponseWriter, r *http.Request) {
	content, err := os.ReadFile(filepath.Join(h.Dir, "index.html"))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.ServeContent(w, r, "index.html", time.Time{}, bytes.NewReader(content))
}
