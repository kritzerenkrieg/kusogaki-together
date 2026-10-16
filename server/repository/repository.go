// Package repository is the level repository: players upload levels, browse
// them and download them, over plain HTTP. A level is stored as its package
// (package.go) under its id, the package's sha256, so a download is checked
// by the game against the id it asked for. No accounts yet: uploads carry a
// player name and are rate-limited per address. See README.md.
package repository

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"sync"
	"time"

	"kusogaki-together/server/relay"
)

const (
	PageSize      = 8
	MaxLevels     = 5000
	MaxStored     = 4 << 30     // bytes of every package together
	uploadBurst   = 10.0        // new uploads per address ...
	uploadPerSec  = 10.0 / 3600 // ... refilled per second
	maxAuthor     = 16
	packageSuffix = ".pkg"
	infoSuffix    = ".json"
)

var idRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

// Store keeps the levels in a directory: <id>.pkg (the package) and
// <id>.json (its Level), read back at start.
type Store struct {
	dir    string
	mu     sync.Mutex
	levels map[string]*Level
	order  []*Level // newest first
	stored int
	limits map[netip.Addr]*relay.Bucket

	Now func() time.Time
	Log func(format string, args ...any)
}

// Open opens (creating it if needed) the repository in dir.
func Open(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, err
	}
	s := &Store{dir: dir, levels: map[string]*Level{}, limits: map[netip.Addr]*relay.Bucket{},
		Now: time.Now, Log: func(string, ...any) {}}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		name := entry.Name()
		id := name[:len(name)-len(filepath.Ext(name))]
		if filepath.Ext(name) != infoSuffix || !idRe.MatchString(id) {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, name))
		var level Level
		if err != nil || json.Unmarshal(data, &level) != nil || level.ID != id {
			continue
		}
		if _, err := os.Stat(filepath.Join(dir, id+packageSuffix)); err != nil {
			continue
		}
		s.levels[id] = &level
		s.order = append(s.order, &level)
		s.stored += level.Size
	}
	s.sortOrder()
	return s, nil
}

func (s *Store) sortOrder() {
	sort.SliceStable(s.order, func(i, j int) bool {
		if s.order[i].Uploaded != s.order[j].Uploaded {
			return s.order[i].Uploaded > s.order[j].Uploaded
		}
		return s.order[i].ID < s.order[j].ID
	})
}

// Count is the number of stored levels.
func (s *Store) Count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.order)
}

// Add stores a package uploaded from addr by author. It returns the level
// (the stored one when the package was there already) and whether it is new.
func (s *Store) Add(pkg []byte, author string, addr netip.Addr) (Level, bool, error) {
	level, err := Check(pkg)
	if err != nil {
		return Level{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if old := s.levels[level.ID]; old != nil {
		return *old, false, nil
	}
	b := s.limits[addr]
	if b == nil {
		b = &relay.Bucket{}
		s.limits[addr] = b
	}
	if !b.Take(1, s.Now(), uploadPerSec, uploadBurst) {
		return Level{}, false, errLimited
	}
	if len(s.order) >= MaxLevels || s.stored+len(pkg) > MaxStored {
		return Level{}, false, errors.New("the repository is full")
	}
	level.Author = Clean(author, maxAuthor)
	level.Uploaded = s.Now().Unix()
	info, _ := json.Marshal(level)
	if err := writeFile(filepath.Join(s.dir, level.ID+packageSuffix), pkg); err != nil {
		return Level{}, false, errStorage
	}
	if err := writeFile(filepath.Join(s.dir, level.ID+infoSuffix), info); err != nil {
		os.Remove(filepath.Join(s.dir, level.ID+packageSuffix))
		return Level{}, false, errStorage
	}
	stored := level
	s.levels[level.ID] = &stored
	s.order = append(s.order, &stored)
	s.stored += level.Size
	s.sortOrder()
	s.Log("level %s uploaded (%s, %d bytes, %d levels)", level.ID[:12], level.Name, level.Size, len(s.order))
	return level, true, nil
}

var (
	errLimited = errors.New("too many uploads, wait a while")
	errStorage = errors.New("the server could not store the level")
)

// writeFile writes through a temporary file, so a crash leaves no half file.
func writeFile(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Page is one page of the list, newest first.
func (s *Store) Page(page int) (levels []Level, pages int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	pages = max(1, (len(s.order)+PageSize-1)/PageSize)
	page = min(max(page, 1), pages)
	levels = []Level{}
	for _, level := range s.order[min((page-1)*PageSize, len(s.order)):min(page*PageSize, len(s.order))] {
		levels = append(levels, *level)
	}
	return levels, pages
}

// Get returns a stored level's description.
func (s *Store) Get(id string) (Level, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	level := s.levels[id]
	if level == nil {
		return Level{}, false
	}
	return *level, true
}

// Sweep forgets rate limits that are full again (call it now and then).
func (s *Store) Sweep() {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.Now()
	for addr, b := range s.limits {
		if b.Idle(now).Seconds()*uploadPerSec >= uploadBurst {
			delete(s.limits, addr)
		}
	}
}

// Handler serves the API:
//
//	GET  /levels?page=N      {"page", "pages", "levels": [Level...]}, newest first
//	GET  /levels/{id}/info   Level
//	GET  /levels/{id}        the package
//	POST /levels             body: a package; header X-Author: the player's name -> Level
func (s *Store) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /levels", func(w http.ResponseWriter, r *http.Request) {
		page, _ := strconv.Atoi(r.URL.Query().Get("page"))
		levels, pages := s.Page(page)
		writeJSON(w, http.StatusOK, map[string]any{"page": min(max(page, 1), pages), "pages": pages, "levels": levels})
	})
	mux.HandleFunc("GET /levels/{id}/info", func(w http.ResponseWriter, r *http.Request) {
		level, ok := s.Get(r.PathValue("id"))
		if !ok {
			writeError(w, http.StatusNotFound, "no such level")
			return
		}
		writeJSON(w, http.StatusOK, level)
	})
	mux.HandleFunc("GET /levels/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if _, ok := s.Get(id); !ok {
			writeError(w, http.StatusNotFound, "no such level")
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		http.ServeFile(w, r, filepath.Join(s.dir, id+packageSuffix))
	})
	mux.HandleFunc("POST /levels", func(w http.ResponseWriter, r *http.Request) {
		pkg, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxPackage))
		if err != nil {
			writeError(w, http.StatusRequestEntityTooLarge, "the level is too big (16 MB at most)")
			return
		}
		level, created, err := s.Add(pkg, r.Header.Get("X-Author"), remoteAddr(r))
		switch {
		case errors.Is(err, errLimited):
			writeError(w, http.StatusTooManyRequests, err.Error())
		case errors.Is(err, errStorage):
			writeError(w, http.StatusInternalServerError, err.Error())
		case err != nil:
			writeError(w, http.StatusBadRequest, err.Error())
		case created:
			writeJSON(w, http.StatusCreated, level)
		default:
			writeJSON(w, http.StatusOK, level)
		}
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "not found")
	})
	return mux
}

func remoteAddr(r *http.Request) netip.Addr {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return netip.Addr{}
	}
	addr, _ := netip.ParseAddr(host)
	return addr.Unmap()
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}
