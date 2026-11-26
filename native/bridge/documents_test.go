package leafmeshbridge

import (
	"errors"
	"os"
	"testing"
)

type testStorage struct{ calls int }

func (s *testStorage) Request(string) string { s.calls++; return `{"result":[]}` }

func TestDocumentPathsStayInsideGrant(t *testing.T) {
	provider := &testStorage{}
	documentStorage = provider
	fs := &documentFS{root: "content%3A%2F%2Ftest"}
	for _, name := range []string{"../outside", "/absolute", "a/../outside", "a\\outside", "a\x00b"} {
		if err := fs.call("stat", name, nil, nil); !errors.Is(err, os.ErrPermission) {
			t.Fatalf("unsafe path accepted: %q: %v", name, err)
		}
	}
	if provider.calls != 0 {
		t.Fatal("unsafe paths reached Android provider")
	}
	if err := fs.call("names", "folder/notes", nil, nil); err != nil {
		t.Fatal(err)
	}
	if provider.calls != 1 {
		t.Fatal("valid path did not reach provider")
	}
}
