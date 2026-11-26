package leafmeshbridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path"
	"strings"
	"time"

	"github.com/syncthing/syncthing/lib/fs"
	"github.com/syncthing/syncthing/lib/protocol"
)

type documentFS struct {
	root    string
	options []fs.Option
}
type documentInfo struct {
	Filename  string `json:"name"`
	Bytes     int64  `json:"size"`
	Modified  int64  `json:"modified"`
	Directory bool   `json:"directory"`
}

func (i documentInfo) Name() string { return i.Filename }
func (i documentInfo) Size() int64  { return i.Bytes }
func (i documentInfo) Mode() fs.FileMode {
	if i.Directory {
		return fs.FileMode(os.ModeDir) | 0700
	}
	return 0600
}
func (i documentInfo) ModTime() time.Time { return time.UnixMilli(i.Modified) }
func (i documentInfo) IsDir() bool        { return i.Directory }
func (i documentInfo) Sys() any           { return nil }
func (i documentInfo) IsRegular() bool    { return !i.Directory }
func (i documentInfo) IsSymlink() bool    { return false }
func (i documentInfo) Owner() int         { return -1 }
func (i documentInfo) Group() int         { return -1 }

func newDocumentFilesystem(root string, opts ...fs.Option) (fs.Filesystem, error) {
	if documentStorage == nil {
		return nil, fmt.Errorf("Android storage is unavailable")
	}
	return &documentFS{root: root, options: opts}, nil
}
func (f *documentFS) call(op, name string, extra map[string]any, result any) error {
	if strings.ContainsRune(name, 0) || strings.Contains(name, "\\") || path.IsAbs(name) {
		return os.ErrPermission
	}
	if name == "." {
		name = ""
	}
	if name != "" && (path.Clean(name) != name || name == ".." || strings.HasPrefix(name, "../")) {
		return os.ErrPermission
	}
	request := map[string]any{"op": op, "root": f.root, "path": name}
	for key, value := range extra {
		request[key] = value
	}
	payload, err := json.Marshal(request)
	if err != nil {
		return err
	}
	var response struct {
		Result json.RawMessage `json:"result"`
		Error  string          `json:"error"`
		Code   string          `json:"code"`
	}
	if err = json.Unmarshal([]byte(documentStorage.Request(string(payload))), &response); err != nil {
		return err
	}
	if response.Error != "" {
		var cause error = errors.New(response.Error)
		switch response.Code {
		case "notFound":
			cause = os.ErrNotExist
		case "permission":
			cause = os.ErrPermission
		case "exists":
			cause = os.ErrExist
		}
		return &os.PathError{Op: op, Path: name, Err: cause}
	}
	if result != nil {
		return json.Unmarshal(response.Result, result)
	}
	return nil
}
func (f *documentFS) Chmod(string, fs.FileMode) error     { return nil }
func (f *documentFS) Lchown(string, string, string) error { return nil }

// The core's mtime wrapper records virtual times for document providers.
func (f *documentFS) Chtimes(name string, a, m time.Time) error {
	return f.call("touch", name, map[string]any{"modified": m.UnixMilli()}, nil)
}
func (f *documentFS) Create(name string) (fs.File, error) {
	return f.OpenFile(name, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0600)
}
func (f *documentFS) CreateSymlink(string, string) error { return os.ErrPermission }
func (f *documentFS) DirNames(name string) ([]string, error) {
	var result []string
	err := f.call("names", name, nil, &result)
	return result, err
}
func (f *documentFS) Lstat(name string) (fs.FileInfo, error) { return f.Stat(name) }
func (f *documentFS) Mkdir(name string, _ fs.FileMode) error { return f.call("mkdir", name, nil, nil) }
func (f *documentFS) MkdirAll(name string, _ fs.FileMode) error {
	return f.call("mkdirAll", name, nil, nil)
}
func (f *documentFS) Open(name string) (fs.File, error) { return f.OpenFile(name, os.O_RDONLY, 0) }
func (f *documentFS) OpenFile(name string, flags int, _ fs.FileMode) (fs.File, error) {
	var fd int64
	err := f.call("open", name, map[string]any{"flags": flags}, &fd)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), name)
	if file == nil {
		return nil, fmt.Errorf("invalid Android document descriptor")
	}
	return &documentFile{File: file, filesystem: f, name: name}, nil
}
func (f *documentFS) ReadSymlink(string) (string, error) { return "", os.ErrInvalid }
func (f *documentFS) Remove(name string) error {
	return f.call("remove", name, map[string]any{"recursive": false}, nil)
}
func (f *documentFS) RemoveAll(name string) error {
	return f.call("remove", name, map[string]any{"recursive": true}, nil)
}
func (f *documentFS) Rename(old, new string) error {
	return f.call("rename", old, map[string]any{"target": new, "replace": true}, nil)
}
func (f *documentFS) Stat(name string) (fs.FileInfo, error) {
	var result documentInfo
	err := f.call("stat", name, nil, &result)
	return result, err
}
func (f *documentFS) Walk(name string, callback fs.WalkFunc) error {
	info, err := f.Lstat(name)
	if err != nil {
		return callback(name, nil, err)
	}
	if err = callback(name, info, nil); err != nil {
		if err == fs.SkipDir {
			return nil
		}
		return err
	}
	if !info.IsDir() {
		return nil
	}
	children, err := f.DirNames(name)
	if err != nil {
		return callback(name, info, err)
	}
	for _, child := range children {
		if err := f.Walk(path.Join(name, child), callback); err != nil {
			return err
		}
	}
	return nil
}
func (f *documentFS) Watch(string, fs.Matcher, context.Context, bool) (<-chan fs.Event, <-chan error, error) {
	return nil, nil, fs.ErrWatchNotSupported
}
func (f *documentFS) Hide(string) error   { return nil }
func (f *documentFS) Unhide(string) error { return nil }
func (f *documentFS) Glob(pattern string) ([]string, error) {
	var result []string
	err := f.Walk(".", func(name string, info fs.FileInfo, err error) error {
		if err != nil {
			return err
		}
		matched, e := path.Match(pattern, name)
		if e != nil {
			return e
		}
		if matched {
			result = append(result, name)
		}
		return nil
	})
	return result, err
}
func (f *documentFS) Roots() ([]string, error) { return []string{f.root}, nil }
func (f *documentFS) Usage(string) (fs.Usage, error) {
	var result struct {
		Free  uint64 `json:"free"`
		Total uint64 `json:"total"`
	}
	err := f.call("usage", "", nil, &result)
	return fs.Usage{Free: result.Free, Total: result.Total}, err
}
func (f *documentFS) Type() fs.FilesystemType { return fs.FilesystemType("leafmeshsaf") }
func (f *documentFS) URI() string             { return f.root }
func (f *documentFS) Options() []fs.Option    { return f.options }
func (f *documentFS) SameFile(a, b fs.FileInfo) bool {
	return a.Name() == b.Name() && a.Size() == b.Size() && a.ModTime() == b.ModTime()
}
func (f *documentFS) PlatformData(string, bool, bool, fs.XattrFilter) (protocol.PlatformData, error) {
	return protocol.PlatformData{}, nil
}
func (f *documentFS) GetXattr(string, fs.XattrFilter) ([]protocol.Xattr, error) {
	return nil, fs.ErrXattrsNotSupported
}
func (f *documentFS) SetXattr(string, []protocol.Xattr, fs.XattrFilter) error {
	return fs.ErrXattrsNotSupported
}

type documentFile struct {
	*os.File
	filesystem *documentFS
	name       string
}

func (f *documentFile) Stat() (fs.FileInfo, error) { return f.filesystem.Stat(f.name) }

var _ fs.Filesystem = (*documentFS)(nil)
var _ fs.File = (*documentFile)(nil)
