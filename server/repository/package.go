package repository

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"regexp"
	"strconv"
	"strings"
)

// The package format and its rules, the same as the game's
// core/levelpack.lua: the level's files in byte order of their paths, each
// as `path \0 size \0 contents`. Its id is the sha256 of the whole package.
const (
	MaxPackage = 16 << 20  // bytes in a whole package
	MaxFiles   = 256       // files in a package
	MaxLua     = 200 << 10 // bytes of every script together
)

var (
	partRe       = regexp.MustCompile(`^[A-Za-z0-9_-][A-Za-z0-9_.-]*$`)
	scriptRe     = regexp.MustCompile(`^[A-Za-z0-9_]+\.lua$`)
	assetExt     = map[string]bool{"png": true, "jpg": true, "jpeg": true, "wav": true, "ogg": true, "mp3": true}
	errTruncated = errors.New("the package is cut short")
)

// Allowed reports whether a level may have a file at path: level.json,
// entities/<name>.lua, scripts/<name>.lua, or an image or sound under
// assets/. Parts never start with a dot; at most 4 deep, 100 characters.
func Allowed(path string) bool {
	if len(path) == 0 || len(path) > 100 {
		return false
	}
	parts := strings.Split(path, "/")
	if len(parts) > 4 {
		return false
	}
	for _, part := range parts {
		if !partRe.MatchString(part) {
			return false
		}
	}
	switch {
	case path == "level.json":
		return true
	case len(parts) == 2 && (parts[0] == "entities" || parts[0] == "scripts"):
		return scriptRe.MatchString(parts[1])
	case parts[0] == "assets" && len(parts) >= 2:
		name := parts[len(parts)-1]
		dot := strings.LastIndexByte(name, '.')
		return dot >= 0 && assetExt[strings.ToLower(name[dot+1:])]
	}
	return false
}

// File is one file of a package.
type File struct {
	Path string
	Data []byte
}

// Unpack checks a package against every rule and returns its files.
func Unpack(pkg []byte) ([]File, error) {
	if len(pkg) > MaxPackage {
		return nil, errors.New("the package is too big")
	}
	var files []File
	lua := 0
	last := ""
	for at := 0; at < len(pkg); {
		pathEnd := bytes.IndexByte(pkg[at:], 0)
		if pathEnd < 0 {
			return nil, errTruncated
		}
		pathEnd += at
		sizeEnd := bytes.IndexByte(pkg[pathEnd+1:], 0)
		if sizeEnd < 0 {
			return nil, errTruncated
		}
		sizeEnd += pathEnd + 1
		path, sizeText := string(pkg[at:pathEnd]), string(pkg[pathEnd+1:sizeEnd])
		if !Allowed(path) {
			return nil, errors.New("a level may not have the file " + path)
		}
		if len(files) > 0 && path <= last {
			return nil, errors.New("the package's files are out of order")
		}
		size, err := strconv.Atoi(sizeText)
		if err != nil || size < 0 || len(sizeText) > 9 || strconv.Itoa(size) != sizeText || sizeEnd+1+size > len(pkg) {
			return nil, errTruncated
		}
		data := pkg[sizeEnd+1 : sizeEnd+1+size]
		if strings.HasSuffix(path, ".lua") {
			if len(data) > 0 && data[0] == 0x1b {
				return nil, errors.New("compiled Lua is not allowed: " + path)
			}
			lua += size
		} else if err := checkMagic(path, data); err != nil {
			return nil, err
		}
		files = append(files, File{path, data})
		if len(files) > MaxFiles {
			return nil, errors.New("a level has at most " + strconv.Itoa(MaxFiles) + " files")
		}
		last, at = path, sizeEnd+1+size
	}
	if lua > MaxLua {
		return nil, errors.New("the scripts are too big")
	}
	return files, nil
}

// checkMagic: an asset's first bytes must match its extension.
func checkMagic(path string, data []byte) error {
	if path == "level.json" {
		return nil
	}
	ext := strings.ToLower(path[strings.LastIndexByte(path, '.')+1:])
	ok := false
	switch ext {
	case "png":
		ok = bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n"))
	case "jpg", "jpeg":
		ok = bytes.HasPrefix(data, []byte{0xff, 0xd8, 0xff})
	case "wav":
		ok = len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WAVE"
	case "ogg":
		ok = bytes.HasPrefix(data, []byte("OggS"))
	case "mp3":
		ok = bytes.HasPrefix(data, []byte("ID3")) || (len(data) >= 2 && data[0] == 0xff && data[1]&0xe0 == 0xe0)
	}
	if !ok {
		return errors.New(path + " is not a real " + ext + " file")
	}
	return nil
}

// Level is what the list shows about a stored level.
type Level struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Author   string `json:"author"`
	Size     int    `json:"size"`
	Uploaded int64  `json:"uploaded"` // unix seconds
}

var nameRe = regexp.MustCompile(`^[A-Za-z0-9_]+$`)

// Check validates a package and describes it: its id and the level's name
// (level.json `name`: letters, digits and _, at most 32, as rooms carry it).
func Check(pkg []byte) (Level, error) {
	files, err := Unpack(pkg)
	if err != nil {
		return Level{}, err
	}
	var levelJSON []byte
	for _, f := range files {
		if f.Path == "level.json" {
			levelJSON = f.Data
		}
	}
	if levelJSON == nil {
		return Level{}, errors.New("the package has no level.json")
	}
	var data map[string]any
	if err := json.Unmarshal(levelJSON, &data); err != nil {
		return Level{}, errors.New("level.json is not valid JSON")
	}
	if format, _ := data["format"].(float64); format != 1 {
		return Level{}, errors.New("level.json: unsupported format")
	}
	name, _ := data["name"].(string)
	if !nameRe.MatchString(name) || len(name) > 32 {
		return Level{}, errors.New("level.json: name must be letters, digits and _ (at most 32)")
	}
	sum := sha256.Sum256(pkg)
	return Level{ID: hex.EncodeToString(sum[:]), Name: name, Size: len(pkg)}, nil
}

// Clean keeps printable ASCII, at most max bytes.
func Clean(text string, max int) string {
	var b strings.Builder
	for i := 0; i < len(text) && b.Len() < max; i++ {
		if text[i] >= 32 && text[i] <= 126 {
			b.WriteByte(text[i])
		}
	}
	return b.String()
}
