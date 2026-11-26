// Leafmesh's Android host for the unmodified Syncthing v2.1.7 application.
// This package is copied under the pinned upstream module by build_android.py.
package leafmeshbridge

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/fs"
	"github.com/syncthing/syncthing/lib/locations"
	"github.com/syncthing/syncthing/lib/svcutil"
	"github.com/syncthing/syncthing/lib/syncthing"
)

// Storage is implemented by Android's ContentResolver adapter.
// Calls are made from Go workers; the implementation must be thread-safe.
type Storage interface {
	Request(requestJSON string) string
}

var lifecycle sync.Mutex
var application *syncthing.App
var stopServices context.CancelFunc
var documentStorage Storage

func Start(home string, port int, key string, storage Storage) error {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if application != nil {
		return fmt.Errorf("core already running")
	}
	if port < 1024 || port > 65535 || len(key) < 32 {
		return fmt.Errorf("invalid local API configuration")
	}
	if err := os.MkdirAll(home, 0700); err != nil {
		return err
	}
	if err := locations.SetBaseDir(locations.ConfigBaseDir, home); err != nil {
		return err
	}
	if err := locations.SetBaseDir(locations.DataBaseDir, home); err != nil {
		return err
	}
	documentStorage = storage
	fs.RegisterFilesystemType(fs.FilesystemType("leafmeshsaf"), newDocumentFilesystem)
	certificate, err := syncthing.LoadOrGenerateCertificate(filepath.Join(home, "cert.pem"), filepath.Join(home, "key.pem"))
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	logger := events.NewLogger()
	go logger.Serve(ctx)
	cfg, err := syncthing.LoadConfigAtStartup(filepath.Join(home, "config.xml"), certificate, logger, false, false)
	if err != nil {
		cancel()
		return err
	}
	go cfg.Serve(ctx)
	waiter, err := cfg.Modify(func(c *config.Configuration) {
		c.GUI.Enabled = true
		c.GUI.RawAddress = fmt.Sprintf("127.0.0.1:%d", port)
		c.GUI.APIKey = key
		c.Options.StartBrowser = false
		c.Options.AutoUpgradeIntervalH = 0
		c.Options.URAccepted = -1
		c.Options.CREnabled = false
	})
	if err != nil {
		cancel()
		return err
	}
	waiter.Wait()
	if err := cfg.Save(); err != nil {
		cancel()
		return err
	}
	database, err := syncthing.OpenDatabase(locations.Get(locations.Database), 10920*time.Hour)
	if err != nil {
		cancel()
		return err
	}
	app, err := syncthing.New(cfg, database, logger, certificate, syncthing.Options{NoUpgrade: true, DBMaintenanceInterval: 8 * time.Hour})
	if err != nil {
		database.Close()
		cancel()
		return err
	}
	if err := app.Start(); err != nil {
		cancel()
		return err
	}
	application = app
	stopServices = cancel
	go func() {
		app.Wait()
		lifecycle.Lock()
		defer lifecycle.Unlock()
		if application == app {
			application = nil
			cancel()
			stopServices = nil
		}
	}()
	return nil
}

func Stop() {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if application != nil {
		application.Stop(svcutil.ExitSuccess)
		application = nil
	}
	if stopServices != nil {
		stopServices()
		stopServices = nil
	}
}

func Running() bool {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	return application != nil && application.Error() == nil
}
