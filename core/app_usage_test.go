package core

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/common/atomic"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type usageTracker struct {
	statistic.Tracker
	id   string
	info statistic.TrackerInfo
}

func (t *usageTracker) ID() string                   { return t.id }
func (t *usageTracker) Info() *statistic.TrackerInfo { return &t.info }

func newUsageTracker(id, process, path string) *usageTracker {
	return &usageTracker{id: id, info: statistic.TrackerInfo{
		Metadata:    &constant.Metadata{Process: process, ProcessPath: path},
		UploadTotal: atomic.NewInt64(0), DownloadTotal: atomic.NewInt64(0),
	}}
}

func usageDate(t *testing.T, date string) time.Time {
	t.Helper()
	value, err := time.Parse(appUsageDateLayout, date)
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func usageTotal(t *testing.T, store *appUsageStore, from, to string) int64 {
	t.Helper()
	days, err := store.query(AppUsageParams{From: from, To: to})
	if err != nil {
		t.Fatal(err)
	}
	var total int64
	for _, day := range days {
		for _, app := range day.Apps {
			total += app.Upload + app.Download
		}
	}
	return total
}

func TestAppUsagePersistsWithoutDoubleCounting(t *testing.T) {
	directory := t.TempDir()
	store := newAppUsageStore(directory)
	tracker := newUsageTracker("one", "browser.exe", `C:\Apps\browser.exe`)
	tracker.info.UploadTotal.Add(30)
	tracker.info.DownloadTotal.Add(70)
	store.add(tracker)
	date := usageDate(t, "2026-11-19")
	open := func(string) bool { return true }
	for range 3 {
		if err := store.collect(date, open); err != nil {
			t.Fatal(err)
		}
	}
	if err := store.flush(); err != nil {
		t.Fatal(err)
	}
	if total := usageTotal(t, newAppUsageStore(directory), "2026-11-19", "2026-11-19"); total != 100 {
		t.Fatalf("persisted total = %d, want 100", total)
	}
	tracker.info.DownloadTotal.Add(20)
	if err := store.collect(date, open); err != nil {
		t.Fatal(err)
	}
	if err := store.flush(); err != nil {
		t.Fatal(err)
	}
	restarted := newAppUsageStore(directory)
	if total := usageTotal(t, restarted, "2026-11-19", "2026-11-19"); total != 120 {
		t.Fatalf("replaced total = %d, want 120", total)
	}
	newConnection := newUsageTracker("two", "browser.exe", `C:\Apps\browser.exe`)
	newConnection.info.DownloadTotal.Add(5)
	restarted.add(newConnection)
	if err := restarted.collect(date, open); err != nil {
		t.Fatal(err)
	}
	if total := usageTotal(t, restarted, "2026-11-19", "2026-11-19"); total != 125 {
		t.Fatalf("total after restart = %d, want 125", total)
	}
}

func TestAppUsageKeepsShortConnectionsAndFinalTraffic(t *testing.T) {
	store := newAppUsageStore(t.TempDir())
	tracker := newUsageTracker("short", "app", "")
	store.add(tracker)
	store.add(tracker)
	tracker.info.DownloadTotal.Add(10)
	date := usageDate(t, "2026-11-19")
	closed := func(string) bool { return false }
	if err := store.collect(date, closed); err != nil {
		t.Fatal(err)
	}
	tracker.info.UploadTotal.Add(4)
	if err := store.collect(date, closed); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := store.collect(date, closed); err != nil {
			t.Fatal(err)
		}
	}
	if len(store.requests) != 0 {
		t.Fatal("closed connection retained indefinitely")
	}
	if total := usageTotal(t, store, "2026-11-19", "2026-11-19"); total != 14 {
		t.Fatalf("short connection = %d, want 14", total)
	}
}

func TestAppUsageSplitsLongConnectionsAtLocalMidnight(t *testing.T) {
	store := newAppUsageStore(t.TempDir())
	tracker := newUsageTracker("long", "app", "")
	store.add(tracker)
	zone := time.FixedZone("half-hour", 19800)
	before := time.Date(2026, 11, 19, 23, 59, 59, 0, zone)
	tracker.info.DownloadTotal.Add(10)
	open := func(string) bool { return true }
	if err := store.collect(before, open); err != nil {
		t.Fatal(err)
	}
	tracker.info.DownloadTotal.Add(20)
	if err := store.collect(before.Add(2*time.Second), open); err != nil {
		t.Fatal(err)
	}
	if got := usageTotal(t, store, "2026-11-19", "2026-11-19"); got != 10 {
		t.Fatalf("first day = %d", got)
	}
	if got := usageTotal(t, store, "2026-11-20", "2026-11-20"); got != 20 {
		t.Fatalf("second day = %d", got)
	}
	if _, err := store.query(AppUsageParams{From: "../escape", To: "2026-11-20"}); err == nil {
		t.Fatal("accepted invalid date")
	}
	if _, err := store.query(AppUsageParams{From: "2026-11-20", To: "2026-11-19"}); err == nil {
		t.Fatal("accepted reversed range")
	}
}

func TestAppUsageIdentityAndUnknownProcesses(t *testing.T) {
	if appUsageKey("a.exe", `C:\Apps\A.exe`, true) != appUsageKey("A.exe", "c:/apps/a.exe", true) {
		t.Fatal("Windows case split one app")
	}
	if appUsageKey("APP.exe", "", true) != appUsageKey("app.EXE", "", true) {
		t.Fatal("Windows fallback name split one app")
	}
	if appUsageKey("app", "/Apps/app", false) == appUsageKey("app", "/apps/app", false) {
		t.Fatal("case-sensitive paths merged")
	}
	if appUsageKey("a", "/one/a", false) == appUsageKey("a", "/two/a", false) {
		t.Fatal("different installations merged")
	}
	store := newAppUsageStore(t.TempDir())
	unknown := newUsageTracker("unknown", "", "")
	unknown.info.DownloadTotal.Add(3)
	store.add(unknown)
	internal := newUsageTracker("dns", "core", "")
	internal.info.Metadata.Type = constant.INNER
	internal.info.DownloadTotal.Add(100)
	store.add(internal)
	if err := store.collect(usageDate(t, "2026-11-19"), func(string) bool { return true }); err != nil {
		t.Fatal(err)
	}
	if got := usageTotal(t, store, "2026-11-19", "2026-11-19"); got != 3 {
		t.Fatalf("unknown/internal total = %d", got)
	}
}

func TestAppUsageResolvesWindowsSocketWithoutChangingMetadata(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows socket ownership lookup")
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	client, err := net.Dial("tcp4", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	server, err := listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	tracker := newUsageTracker("unresolved", "", "")
	address := client.LocalAddr().(*net.TCPAddr).AddrPort()
	tracker.info.Metadata.SrcIP, tracker.info.Metadata.SrcPort = address.Addr(), address.Port()
	tracker.info.Metadata.NetWork = constant.TCP
	tracker.info.UploadTotal.Add(10)
	store := newAppUsageStore(t.TempDir())
	store.add(tracker)
	if err := store.collect(usageDate(t, "2026-11-19"), func(string) bool { return true }); err != nil {
		t.Fatal(err)
	}
	path, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	entry := store.days["2026-11-19"].Apps[appUsageEntryKey("", appUsageKey("", path, true))]
	if entry.Upload != 10 || entry.ProcessPath == "" {
		t.Fatalf("unresolved socket was not attributed to its executable: %+v", entry)
	}
	if tracker.info.Metadata.Process != "" || tracker.info.Metadata.ProcessPath != "" {
		t.Fatal("accounting changed the routing metadata")
	}
}

func TestAppUsageKeepsConnectionsWithTheirOpeningProfile(t *testing.T) {
	directory := t.TempDir()
	store := newAppUsageStore(directory)
	store.setProfile(AppUsageProfile{ID: "first", Name: "Same name"})
	first := newUsageTracker("one", "browser", "/apps/browser")
	store.add(first)
	first.info.UploadTotal.Add(10)
	store.setProfile(AppUsageProfile{ID: "second", Name: "Same name"})
	second := newUsageTracker("two", "browser", "/apps/browser")
	store.add(second)
	first.info.DownloadTotal.Add(20)
	second.info.DownloadTotal.Add(40)
	date := usageDate(t, "2026-11-19")
	if err := store.collect(date, func(string) bool { return true }); err != nil {
		t.Fatal(err)
	}
	if err := store.flush(); err != nil {
		t.Fatal(err)
	}
	days, err := newAppUsageStore(directory).query(AppUsageParams{From: "2026-11-19", To: "2026-11-19"})
	if err != nil {
		t.Fatal(err)
	}
	totals := make(map[string]int64)
	for _, app := range days[0].Apps {
		totals[app.ProfileID] += app.Upload + app.Download
	}
	if len(totals) != 2 || totals["first"] != 30 || totals["second"] != 40 {
		t.Fatalf("switched profile totals = %v", totals)
	}
	store.setProfile(AppUsageProfile{ID: "first", Name: "Renamed"})
	first.info.UploadTotal.Add(1)
	third := newUsageTracker("three", "browser", "/apps/browser")
	third.info.UploadTotal.Add(5)
	store.add(third)
	if err := store.collect(date, func(string) bool { return true }); err != nil {
		t.Fatal(err)
	}
	if len(store.days["2026-11-19"].Apps) != 2 {
		t.Fatal("profile rename split its history")
	}
	entry := store.days["2026-11-19"].Apps[appUsageEntryKey("first", appUsageKey("browser", "/apps/browser", runtime.GOOS == "windows"))]
	if entry.ProfileName != "Renamed" {
		t.Fatal("a surviving connection restored the old profile name")
	}
}

func TestAppUsageMigratesLegacyHistoryWithoutAssigningIt(t *testing.T) {
	directory := t.TempDir()
	legacy := AppUsageDay{Version: 1, Date: "2026-11-19", Apps: map[string]AppUsageEntry{
		"browser": {App: "browser", Process: "browser", Upload: 30, Download: 50},
	}}
	data, err := json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "2026-11-19.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	store := newAppUsageStore(directory)
	store.setProfile(AppUsageProfile{ID: "new", Name: "Current"})
	tracker := newUsageTracker("one", "browser", "")
	tracker.info.DownloadTotal.Add(20)
	store.add(tracker)
	if err := store.collect(usageDate(t, "2026-11-19"), func(string) bool { return true }); err != nil {
		t.Fatal(err)
	}
	if err := store.flush(); err != nil {
		t.Fatal(err)
	}
	day, err := readAppUsageDay(filepath.Join(directory, "2026-11-19.json"), "2026-11-19")
	if err != nil {
		t.Fatal(err)
	}
	old := day.Apps[appUsageEntryKey("", "browser")]
	current := day.Apps[appUsageEntryKey("new", "browser")]
	if day.Version != 3 || len(day.Apps) != 2 || old.Upload+old.Download != 80 || current.Download != 20 {
		t.Fatalf("legacy migration changed attribution or totals: %+v", day)
	}
}

func TestAppUsageSeparatesActualProxyTrafficFromDirectAndBlockedTraffic(t *testing.T) {
	keepTunnel(t)
	node, err := adapter.ParseProxy(map[string]any{
		"name": "node", "type": "ss", "server": "127.0.0.1", "port": 1,
		"cipher": "aes-128-gcm", "password": "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	tunnel.UpdateProxies(map[string]constant.Proxy{
		"node":          node,
		"custom-direct": adapter.NewProxy(outbound.NewDirectWithOption(outbound.DirectOption{Name: "custom-direct"})),
		"blocked":       adapter.NewProxy(outbound.NewRejectWithOption(outbound.RejectOption{Name: "blocked"})),
	}, nil)
	store := newAppUsageStore(t.TempDir())
	store.setProfile(AppUsageProfile{ID: "p", Name: "Profile"})
	var proxy *usageTracker
	for _, row := range []struct {
		id       string
		chain    constant.Chain
		up, down int64
	}{
		{"direct", constant.Chain{"custom-direct", "Group"}, 100, 200},
		{"proxy", constant.Chain{"node", "Group", "GLOBAL"}, 10, 20},
		{"blocked", constant.Chain{"blocked"}, 7, 8},
		{"unknown", nil, 3, 4},
	} {
		tracker := newUsageTracker(row.id, "browser", "")
		tracker.info.Chain = row.chain
		tracker.info.UploadTotal.Add(row.up)
		tracker.info.DownloadTotal.Add(row.down)
		store.add(tracker)
		if row.id == "proxy" {
			proxy = tracker
		}
	}
	date := usageDate(t, "2026-11-19")
	if err := store.collect(date, func(string) bool { return true }); err != nil {
		t.Fatal(err)
	}
	key := appUsageEntryKey("p", "browser")
	entry := store.days["2026-11-19"].Apps[key]
	if entry.Upload != 120 || entry.Download != 232 || entry.ProxyUpload != 10 || entry.ProxyDownload != 20 {
		t.Fatalf("direct/blocked bytes counted as proxy usage: %+v", entry)
	}
	tunnel.UpdateProxies(map[string]constant.Proxy{
		"node": adapter.NewProxy(outbound.NewDirectWithOption(outbound.DirectOption{Name: "node"})),
	}, nil)
	proxy.info.UploadTotal.Add(5)
	proxy.info.DownloadTotal.Add(7)
	if err := store.collect(date, func(string) bool { return true }); err != nil {
		t.Fatal(err)
	}
	if err := store.flush(); err != nil {
		t.Fatal(err)
	}
	days, err := newAppUsageStore(store.directory).query(AppUsageParams{From: "2026-11-19", To: "2026-11-19"})
	if err != nil {
		t.Fatal(err)
	}
	entry = days[0].Apps[key]
	if entry.ProxyUpload != 15 || entry.ProxyDownload != 27 {
		t.Fatalf("route change altered an existing connection's accounting: %+v", entry)
	}
}

func TestAppUsageDoesNotTreatVersionTwoTotalsAsProxyTraffic(t *testing.T) {
	directory := t.TempDir()
	key := appUsageEntryKey("p", "browser")
	legacy := AppUsageDay{Version: 2, Date: "2026-11-19", Apps: map[string]AppUsageEntry{
		key: {App: "browser", Process: "browser", ProfileID: "p", ProfileName: "Profile", Upload: 20, Download: 30},
	}}
	data, err := json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "2026-11-19.json")
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	store := newAppUsageStore(directory)
	days, err := store.query(AppUsageParams{From: "2026-11-19", To: "2026-11-19"})
	if err != nil {
		t.Fatal(err)
	}
	entry := days[0].Apps[key]
	if days[0].Version != 3 || entry.Upload+entry.Download != 50 || entry.ProfileID != "p" || entry.ProxyUpload+entry.ProxyDownload != 0 {
		t.Fatalf("legacy totals became proxy usage: %+v", entry)
	}
	unchanged, err := os.ReadFile(path)
	if err != nil || string(unchanged) != string(data) {
		t.Fatal("reading history rewrote its source")
	}
}

func TestAppUsageDoesNotOverwriteCorruptHistory(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "2026-11-19.json")
	if err := os.WriteFile(path, []byte("broken"), 0600); err != nil {
		t.Fatal(err)
	}
	store := newAppUsageStore(directory)
	tracker := newUsageTracker("one", "app", "")
	tracker.info.UploadTotal.Add(10)
	store.add(tracker)
	if err := store.collect(usageDate(t, "2026-11-19"), func(string) bool { return true }); err == nil {
		t.Fatal("corruption ignored")
	}
	if err := store.flush(); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "broken" {
		t.Fatal("corrupt file overwritten")
	}
}

func TestAppUsageRetriesFailedWrites(t *testing.T) {
	path := filepath.Join(t.TempDir(), "history")
	store := newAppUsageStore(path)
	tracker := newUsageTracker("one", "app", "")
	tracker.info.UploadTotal.Add(7)
	store.add(tracker)
	if err := store.collect(usageDate(t, "2026-11-19"), func(string) bool { return true }); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("blocked"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := store.flush(); err == nil {
		t.Fatal("failed write reported success")
	}
	if len(store.versions) != 1 {
		t.Fatal("failed write discarded pending totals")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := store.flush(); err != nil {
		t.Fatal(err)
	}
	if got := usageTotal(t, newAppUsageStore(path), "2026-11-19", "2026-11-19"); got != 7 {
		t.Fatalf("retried total = %d", got)
	}
}

func TestAppUsageConcurrentCollectionAndPersistence(t *testing.T) {
	store := newAppUsageStore(t.TempDir())
	tracker := newUsageTracker("one", "app", "")
	store.add(tracker)
	date := usageDate(t, "2026-11-19")
	var workers sync.WaitGroup
	workers.Add(1)
	go func() {
		defer workers.Done()
		for range 100 {
			tracker.info.UploadTotal.Add(1)
			if err := store.collect(date, func(string) bool { return true }); err != nil {
				t.Error(err)
				return
			}
		}
	}()
	for range 5 {
		if err := store.flush(); err != nil {
			t.Fatal(err)
		}
	}
	workers.Wait()
	if err := store.flush(); err != nil {
		t.Fatal(err)
	}
	if got := usageTotal(t, newAppUsageStore(store.directory), "2026-11-19", "2026-11-19"); got != 100 {
		t.Fatalf("concurrent total = %d", got)
	}
}
