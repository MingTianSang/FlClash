package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/component/iface"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/constant/features"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const appUsageDateLayout = "2006-01-02"

type AppUsageEntry struct {
	App           string `json:"app"`
	Process       string `json:"process"`
	ProcessPath   string `json:"processPath"`
	Upload        int64  `json:"upload"`
	Download      int64  `json:"download"`
	ProfileID     string `json:"profileId"`
	ProfileName   string `json:"profileName"`
	ProxyUpload   int64  `json:"proxyUpload"`
	ProxyDownload int64  `json:"proxyDownload"`
}

type AppUsageProfile struct {
	ID   string
	Name string
}

type AppUsageDay struct {
	Version int                      `json:"version"`
	Date    string                   `json:"date"`
	Apps    map[string]AppUsageEntry `json:"apps"`
}

type AppUsageParams struct {
	From string `json:"from"`
	To   string `json:"to"`
}

type appUsageRequest struct {
	tracker          statistic.Tracker
	profile          AppUsageProfile
	proxy            bool
	process, path    string
	upload, download int64
	fresh            bool
	closedSamples    int
}

type appUsageStore struct {
	mu           sync.Mutex
	writeMu      sync.Mutex
	directory    string
	requests     map[string]*appUsageRequest
	days         map[string]*AppUsageDay
	versions     map[string]uint64
	running      bool
	profile      AppUsageProfile
	profileNames map[string]string
}

var currentAppUsage = newAppUsageStore("")

func newAppUsageStore(directory string) *appUsageStore {
	return &appUsageStore{
		directory:    directory,
		requests:     make(map[string]*appUsageRequest),
		days:         make(map[string]*AppUsageDay),
		versions:     make(map[string]uint64),
		profileNames: make(map[string]string),
	}
}

func (s *appUsageStore) configure(home string) {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	directory := filepath.Join(home, "app_usage")
	if s.directory != directory {
		s.directory = directory
		s.requests = make(map[string]*appUsageRequest)
		s.days = make(map[string]*AppUsageDay)
		s.versions = make(map[string]uint64)
		s.profile = AppUsageProfile{}
		s.profileNames = make(map[string]string)
	}
}

func (s *appUsageStore) setProfile(profile AppUsageProfile) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.profile = profile
	s.profileNames[profile.ID] = profile.Name
}

func appUsageEntryKey(profileID, app string) string {
	key, _ := json.Marshal([2]string{profileID, app})
	return string(key)
}

func appUsageKey(process, path string, windows bool) string {
	if path == "" {
		path = process
	}
	if windows {
		return strings.ToLower(strings.ReplaceAll(path, "\\", "/"))
	}
	return path
}

func findAppUsageProcess(metadata *constant.Metadata) (string, string) {
	if metadata == nil {
		return "", ""
	}
	if metadata.Process != "" || metadata.ProcessPath != "" {
		return metadata.Process, metadata.ProcessPath
	}
	if features.Android {
		copy := *metadata
		name, _ := process.FindPackageName(&copy)
		return name, ""
	}
	if !metadata.SrcIP.IsValid() || metadata.SrcPort == 0 {
		return "", ""
	}
	local, err := iface.IsLocalIp(metadata.SrcIP)
	if err != nil || !local {
		return "", ""
	}
	_, path, err := process.FindProcessName(metadata.NetWork.String(), metadata.SrcIP, int(metadata.SrcPort))
	if err != nil || path == "" {
		return "", ""
	}
	return filepath.Base(path), path
}

func appUsageUsesProxy(chain constant.Chain) bool {
	if len(chain) == 0 {
		return false
	}
	proxy, ok := tunnel.AllProxies()[chain.Last()]
	if !ok {
		return false
	}
	switch proxy.Type() {
	case constant.Direct, constant.Reject, constant.RejectDrop, constant.Compatible,
		constant.Pass, constant.PassRule, constant.Rematch, constant.Dns,
		constant.Relay, constant.Selector, constant.Fallback, constant.URLTest, constant.LoadBalance:
		return false
	default:
		return true
	}
}

func (s *appUsageStore) add(tracker statistic.Tracker) bool {
	info := tracker.Info()
	if info.Metadata != nil && info.Metadata.Type == constant.INNER {
		return false
	}
	s.mu.Lock()
	_, exists := s.requests[tracker.ID()]
	if s.directory == "" || exists {
		s.mu.Unlock()
		return false
	}
	profile := s.profile
	s.mu.Unlock()
	proxy := appUsageUsesProxy(info.Chain)
	process, path := findAppUsageProcess(info.Metadata)
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.requests[tracker.ID()]; !exists {
		s.requests[tracker.ID()] = &appUsageRequest{tracker: tracker, profile: profile, proxy: proxy, process: process, path: path, fresh: true}
	}
	start := !s.running
	s.running = true
	return start
}

func readAppUsageDay(path, date string) (*AppUsageDay, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return &AppUsageDay{Version: 3, Date: date, Apps: make(map[string]AppUsageEntry)}, nil
	}
	if err != nil {
		return nil, err
	}
	var day AppUsageDay
	if err := json.Unmarshal(data, &day); err != nil {
		return nil, err
	}
	if day.Version < 1 || day.Version > 3 || day.Date != date || day.Apps == nil {
		return nil, errors.New("invalid application usage history")
	}
	if day.Version == 1 {
		apps := make(map[string]AppUsageEntry, len(day.Apps))
		for _, entry := range day.Apps {
			entry.ProfileID, entry.ProfileName = "", ""
			apps[appUsageEntryKey("", entry.App)] = entry
		}
		day.Version, day.Apps = 2, apps
	}
	if day.Version < 3 {
		for key, entry := range day.Apps {
			entry.ProxyUpload, entry.ProxyDownload = 0, 0
			day.Apps[key] = entry
		}
		day.Version = 3
	}
	return &day, nil
}

func (s *appUsageStore) collect(now time.Time, isOpen func(string) bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	date := now.Format(appUsageDateLayout)
	for id, request := range s.requests {
		info := request.tracker.Info()
		upload, download := info.UploadTotal.Load(), info.DownloadTotal.Load()
		up, down := max(0, upload-request.upload), max(0, download-request.download)
		if up != 0 || down != 0 {
			day := s.days[date]
			if day == nil {
				var err error
				day, err = readAppUsageDay(filepath.Join(s.directory, date+".json"), date)
				if err != nil {
					return err
				}
				s.days[date] = day
			}
			process, path := request.process, request.path
			app := appUsageKey(process, path, runtime.GOOS == "windows")
			key := appUsageEntryKey(request.profile.ID, app)
			entry := day.Apps[key]
			entry.App, entry.Process, entry.ProcessPath = app, process, path
			entry.ProfileID, entry.ProfileName = request.profile.ID, s.profileNames[request.profile.ID]
			entry.Upload += up
			entry.Download += down
			if request.proxy {
				entry.ProxyUpload += up
				entry.ProxyDownload += down
			}
			day.Apps[key] = entry
			s.versions[date]++
			request.closedSamples = 0
		} else if !request.fresh && !isOpen(id) {
			request.closedSamples++
		}
		request.upload, request.download = upload, download
		request.fresh = false
		// Keep a closed tracker for two stable samples to include its final I/O.
		if request.closedSamples >= 2 {
			delete(s.requests, id)
		}
	}
	return nil
}

func copyAppUsageDay(day *AppUsageDay) AppUsageDay {
	apps := make(map[string]AppUsageEntry, len(day.Apps))
	for key, entry := range day.Apps {
		apps[key] = entry
	}
	return AppUsageDay{Version: 3, Date: day.Date, Apps: apps}
}

func writeAppUsageDay(directory string, day AppUsageDay) error {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	reclaimDirOwnership(directory)
	file, err := os.CreateTemp(directory, ".usage-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if os.Getuid() != os.Geteuid() {
		if err := file.Chown(os.Getuid(), os.Getgid()); err != nil {
			return err
		}
	}
	if err := json.NewEncoder(file).Encode(day); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), filepath.Join(directory, day.Date+".json"))
}

func (s *appUsageStore) flush() error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.mu.Lock()
	directory := s.directory
	days := make(map[string]AppUsageDay)
	versions := make(map[string]uint64)
	for date, version := range s.versions {
		days[date] = copyAppUsageDay(s.days[date])
		versions[date] = version
	}
	s.mu.Unlock()
	for date, day := range days {
		if err := writeAppUsageDay(directory, day); err != nil {
			return err
		}
		s.mu.Lock()
		if s.versions[date] == versions[date] {
			delete(s.versions, date)
			if date != time.Now().Format(appUsageDateLayout) {
				delete(s.days, date)
			}
		}
		s.mu.Unlock()
	}
	return nil
}

func (s *appUsageStore) query(params AppUsageParams) ([]AppUsageDay, error) {
	from, err := time.Parse(appUsageDateLayout, params.From)
	if err != nil {
		return nil, errors.New("invalid usage start date")
	}
	to, err := time.Parse(appUsageDateLayout, params.To)
	if err != nil || to.Before(from) {
		return nil, errors.New("invalid usage end date")
	}
	s.mu.Lock()
	directory := s.directory
	days := make(map[string]AppUsageDay)
	for date, day := range s.days {
		if date >= params.From && date <= params.To {
			days[date] = copyAppUsageDay(day)
		}
	}
	s.mu.Unlock()
	files, err := os.ReadDir(directory)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	for _, file := range files {
		date, ok := strings.CutSuffix(file.Name(), ".json")
		if !ok || file.IsDir() || date < params.From || date > params.To {
			continue
		}
		if _, err := time.Parse(appUsageDateLayout, date); err != nil {
			continue
		}
		if _, exists := days[date]; exists {
			continue
		}
		day, err := readAppUsageDay(filepath.Join(directory, file.Name()), date)
		if err != nil {
			return nil, err
		}
		days[date] = *day
	}
	result := make([]AppUsageDay, 0, len(days))
	for _, day := range days {
		result = append(result, day)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Date < result[j].Date })
	return result, nil
}

func watchAppUsage(tracker statistic.Tracker) {
	if !isInit.Load() {
		return
	}
	if currentAppUsage.add(tracker) {
		go runAppUsageWatch()
	}
}

func collectAppUsage() error {
	return currentAppUsage.collect(time.Now(), func(id string) bool {
		return statistic.DefaultManager.Get(id) != nil
	})
}

func runAppUsageWatch() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	lastFlush := time.Now()
	reported := false
	for now := range ticker.C {
		err := collectAppUsage()
		if err == nil && now.Sub(lastFlush) >= 5*time.Second {
			err = currentAppUsage.flush()
			lastFlush = now
		}
		if err != nil && !reported {
			fmt.Fprintln(os.Stderr, "Application usage history could not be saved")
		}
		reported = err != nil
		currentAppUsage.mu.Lock()
		idle := len(currentAppUsage.requests) == 0 && len(currentAppUsage.versions) == 0
		if idle {
			currentAppUsage.running = false
		}
		currentAppUsage.mu.Unlock()
		if idle {
			return
		}
	}
}

func handleGetAppUsage(params AppUsageParams) ([]AppUsageDay, error) {
	if err := collectAppUsage(); err != nil {
		return nil, err
	}
	if err := currentAppUsage.flush(); err != nil {
		return nil, err
	}
	return currentAppUsage.query(params)
}

func handleFlushAppUsage() error {
	if err := collectAppUsage(); err != nil {
		return err
	}
	return currentAppUsage.flush()
}
