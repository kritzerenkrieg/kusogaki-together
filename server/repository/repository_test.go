package repository

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

const pngHeader = "\x89PNG\r\n\x1a\n...."

// pack builds a package from files, the way the game does.
func pack(files map[string]string) []byte {
	paths := make([]string, 0, len(files))
	for path := range files {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	var b bytes.Buffer
	for _, path := range paths {
		b.WriteString(path + "\x00" + strconv.Itoa(len(files[path])) + "\x00" + files[path])
	}
	return b.Bytes()
}

func level(name string) map[string]string {
	return map[string]string{
		"level.json":       `{"format": 1, "name": "` + name + `", "spawn": {"x": 0, "y": 0}}`,
		"scripts/goal.lua": "return {}",
		"assets/box.png":   pngHeader,
	}
}

func TestAllowed(t *testing.T) {
	for path, want := range map[string]bool{
		"level.json": true, "entities/box.lua": true, "scripts/goal_2.lua": true,
		"assets/box.png": true, "assets/sfx/hit.OGG": true, "assets/a/b/c.mp3": true,
		"entities/a/box.lua": false, "entities/box.txt": false, "scripts/.x.lua": false,
		"assets/../level.json": false, "assets/.hidden.png": false, "/level.json": false,
		"assets/box": false, "assets/box.gif": false, "readme.md": false, "assets//x.png": false,
		"assets/a/b/c/d.png": false, "": false, "level.json/": false,
	} {
		if Allowed(path) != want {
			t.Errorf("Allowed(%q) = %v", path, !want)
		}
	}
}

func TestCheck(t *testing.T) {
	pkg := pack(level("first"))
	got, err := Check(pkg)
	sum := sha256.Sum256(pkg)
	if err != nil || got.ID != hex.EncodeToString(sum[:]) || got.Name != "first" || got.Size != len(pkg) {
		t.Fatalf("Check = %+v, %v", got, err)
	}
	bad := func(why string, files map[string]string, raw []byte) {
		t.Helper()
		if raw == nil {
			raw = pack(files)
		}
		if _, err := Check(raw); err == nil {
			t.Errorf("%s: accepted", why)
		}
	}
	with := func(path, data string) map[string]string {
		files := level("x")
		files[path] = data
		return files
	}
	without := level("x")
	delete(without, "level.json")
	bad("no level.json", without, nil)
	bad("a file outside the rules", with("notes.txt", "hi"), nil)
	bad("compiled Lua", with("scripts/evil.lua", "\x1bLuaJ"), nil)
	bad("a fake image", with("assets/fake.png", "GIF89a"), nil)
	bad("bad json", with("level.json", "{"), nil)
	bad("another format", with("level.json", `{"format": 2, "name": "x"}`), nil)
	bad("a bad name", with("level.json", `{"format": 1, "name": "a b"}`), nil)
	bad("a long name", with("level.json", `{"format": 1, "name": "`+strings.Repeat("a", 33)+`"}`), nil)
	bad("too much Lua", with("scripts/big.lua", strings.Repeat("-", MaxLua+1)), nil)
	good := pack(level("x"))
	bad("cut short", nil, good[:len(good)-1])
	bad("trailing bytes", nil, append(append([]byte{}, good...), 'x'))
	bad("out of order", nil, []byte("level.json\x002\x00{}assets/box.png\x0012\x00"+pngHeader))
	bad("a padded size", nil, []byte("level.json\x00020\x00"+`{"format":1,"name":"x"}`))
}

func newStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestStore(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1000, 0)
	s.Now = func() time.Time { return now }
	addr := netip.MustParseAddr("10.0.0.1")
	first, created, err := s.Add(pack(level("first")), "Ann\x00ie with a very long name", addr)
	if err != nil || !created || first.Author != "Annie with a ver" || first.Uploaded != 1000 {
		t.Fatalf("Add = %+v %v %v", first, created, err)
	}
	again, created, err := s.Add(pack(level("first")), "Bob", addr)
	if err != nil || created || again.Author != first.Author {
		t.Errorf("the same package again: %+v %v %v", again, created, err)
	}
	if _, _, err := s.Add([]byte("junk"), "Bob", addr); err == nil {
		t.Error("a bad package was stored")
	}
	for i := 0; i < 20; i++ {
		now = now.Add(time.Second)
		s.Add(pack(level("level_"+strconv.Itoa(i))), "Bob", addr)
	}
	if _, _, err := s.Add(pack(level("one_more")), "Bob", addr); err != errLimited {
		t.Errorf("uploads past the limit: %v", err)
	}
	if _, created, err := s.Add(pack(level("other_address")), "Cy", netip.MustParseAddr("10.0.0.2")); err != nil || !created {
		t.Errorf("another address is not limited: %v", err)
	}
	if s.Count() != 11 {
		t.Errorf("count %d, want 11 (10 per address)", s.Count())
	}
	levels, pages := s.Page(1)
	if pages != 2 || len(levels) != PageSize || levels[0].Name != "other_address" {
		t.Errorf("page 1: %d pages, %+v", pages, levels)
	}
	if levels, _ := s.Page(99); len(levels) != 11-PageSize {
		t.Errorf("a page past the end shows the last: %d", len(levels))
	}
	reopened, err := Open(dir)
	if err != nil || reopened.Count() != 11 {
		t.Fatalf("reopened: %v, %d levels", err, reopened.Count())
	}
	if got, ok := reopened.Get(first.ID); !ok || got != first {
		t.Errorf("reopened level: %+v", got)
	}
	now = now.Add(2 * time.Hour)
	s.Sweep()
	if len(s.limits) != 0 {
		t.Error("full limits are forgotten")
	}
}

func TestHandler(t *testing.T) {
	s := newStore(t)
	server := httptest.NewServer(s.Handler())
	defer server.Close()
	post := func(body []byte, author string) (*http.Response, map[string]any) {
		t.Helper()
		req, _ := http.NewRequest("POST", server.URL+"/levels", bytes.NewReader(body))
		req.Header.Set("X-Author", author)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var data map[string]any
		json.NewDecoder(resp.Body).Decode(&data)
		return resp, data
	}
	get := func(path string) (*http.Response, []byte) {
		t.Helper()
		resp, err := http.Get(server.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		return resp, body
	}

	pkg := pack(level("first"))
	resp, data := post(pkg, "Ann")
	id, _ := data["id"].(string)
	if resp.StatusCode != http.StatusCreated || len(id) != 64 || data["author"] != "Ann" {
		t.Fatalf("upload: %d %v", resp.StatusCode, data)
	}
	if resp, _ := post(pkg, "Ann"); resp.StatusCode != http.StatusOK {
		t.Errorf("the same upload again: %d", resp.StatusCode)
	}
	if resp, data := post([]byte("junk"), "Ann"); resp.StatusCode != http.StatusBadRequest || data["error"] == nil {
		t.Errorf("a bad upload: %d %v", resp.StatusCode, data)
	}
	if resp, _ := post(make([]byte, MaxPackage+1), "Ann"); resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Errorf("a big upload: %d", resp.StatusCode)
	}
	if resp, body := get("/levels/" + id); resp.StatusCode != 200 || !bytes.Equal(body, pkg) {
		t.Errorf("download: %d, %d bytes", resp.StatusCode, len(body))
	}
	if resp, body := get("/levels/" + id + "/info"); resp.StatusCode != 200 || !strings.Contains(string(body), `"name":"first"`) {
		t.Errorf("info: %d %s", resp.StatusCode, body)
	}
	if resp, _ := get("/levels/" + strings.Repeat("0", 64)); resp.StatusCode != 404 {
		t.Errorf("a missing level: %d", resp.StatusCode)
	}
	if resp, _ := get("/levels/..%2f..%2fetc%2fpasswd"); resp.StatusCode != 404 {
		t.Errorf("a path as id: %d", resp.StatusCode)
	}
	resp, body := get("/levels?page=1")
	var list struct {
		Page, Pages int
		Levels      []Level
	}
	if json.Unmarshal(body, &list) != nil || resp.StatusCode != 200 || list.Pages != 1 || len(list.Levels) != 1 || list.Levels[0].ID != id {
		t.Errorf("list: %d %s", resp.StatusCode, body)
	}
	if resp, _ := get("/nothing"); resp.StatusCode != 404 {
		t.Errorf("unknown path: %d", resp.StatusCode)
	}
}
