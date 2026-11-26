package leafmeshbridge

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/syncthing"
)

func TestEmbeddedCoreLifecycle(t *testing.T) {
	home := t.TempDir()
	cert, err := syncthing.LoadOrGenerateCertificate(filepath.Join(home, "cert.pem"), filepath.Join(home, "key.pem"))
	if err != nil {
		t.Fatal(err)
	}
	configuration := config.New(protocol.NewDeviceID(cert.Certificate[0]))
	configuration.Options.RawListenAddresses = []string{"tcp://127.0.0.1:0"}
	configuration.Options.GlobalAnnEnabled = false
	configuration.Options.LocalAnnEnabled = false
	configuration.Options.NATEnabled = false
	configuration.Options.RelaysEnabled = false
	configuration.Options.StunKeepaliveStartS = 0
	output, err := os.Create(filepath.Join(home, "config.xml"))
	if err != nil {
		t.Fatal(err)
	}
	if err = configuration.WriteXML(output); err != nil {
		t.Fatal(err)
	}
	output.Close()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	key := "leafmesh-test-only-0123456789-abcdef"
	if err = Start(home, port, key, &testStorage{}); err != nil {
		t.Fatal(err)
	}
	defer Stop()
	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{Proxy: nil}}
	request, _ := http.NewRequest("GET", fmt.Sprintf("http://127.0.0.1:%d/rest/system/ping", port), nil)
	request.Header.Set("X-API-Key", key)
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 200 {
		t.Fatalf("core API returned %d", response.StatusCode)
	}
	if !Running() {
		t.Fatal("core did not report running")
	}
	Stop()
	if Running() {
		t.Fatal("core did not stop")
	}
}
