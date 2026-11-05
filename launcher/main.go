package main

import (
	"crypto/rand"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

var name = "nomad-x5"

const dashboard = "http://localhost:8080"

var root, msb string
var logFile *os.File

//go:embed guest-stop.sh
var guestStopScript string
var storage struct {
	Version       int    `json:"version"`
	Format        string `json:"format"`
	Data          string `json:"data"`
	DockerPattern string `json:"dockerPattern"`
	Seed          string `json:"seed"`
	DockerGiB     int64  `json:"dockerGiB"`
}

func portablePath(rel string) (string, error) {
	clean := filepath.Clean(filepath.FromSlash(rel))
	if rel == "" || filepath.IsAbs(clean) || strings.HasPrefix(clean, "..") {
		return "", errors.New("invalid portable storage path")
	}
	return filepath.Join(root, clean), nil
}

func freeBytes(path string) (int64, error) {
	var b []byte
	var e error
	if runtime.GOOS == "windows" {
		c := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", "([System.IO.DriveInfo]::new($env:NOMAD_DRIVE_ROOT)).AvailableFreeSpace")
		c.Env = append(os.Environ(), "NOMAD_DRIVE_ROOT="+filepath.VolumeName(path)+"\\")
		b, e = c.Output()
	} else {
		b, e = exec.Command("df", "-Pk", filepath.Dir(path)).Output()
		if e == nil {
			lines := strings.Split(strings.TrimSpace(string(b)), "\n")
			fields := strings.Fields(lines[len(lines)-1])
			if len(fields) < 4 {
				return 0, errors.New("cannot parse free disk space")
			}
			n, err := strconv.ParseInt(fields[3], 10, 64)
			return n * 1024, err
		}
	}
	if e != nil {
		return 0, e
	}
	return strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
}

func verifyArtifacts(checkSeed, checkArchive bool) error {
	b, e := os.ReadFile(filepath.Join(root, "release-checksums.json"))
	if e != nil {
		return e
	}
	var entries map[string]string
	if e = json.Unmarshal(b, &entries); e != nil {
		return e
	}
	for rel, want := range entries {
		if rel == storage.Seed && !checkSeed {
			continue
		}
		if strings.HasPrefix(rel, "runtime/") && (!checkArchive || rel != "runtime/ubuntu-"+runtime.GOARCH+".msb") {
			continue
		}
		clean := filepath.Clean(filepath.FromSlash(rel))
		if filepath.IsAbs(clean) || strings.HasPrefix(clean, "..") {
			return errors.New("invalid artifact manifest path")
		}
		f, e := os.Open(filepath.Join(root, clean))
		if e != nil {
			return e
		}
		h := sha256.New()
		_, e = io.Copy(h, f)
		f.Close()
		if e != nil {
			return e
		}
		if hex.EncodeToString(h.Sum(nil)) != want {
			return fmt.Errorf("artifact checksum failed: %s", rel)
		}
	}
	return nil
}

func ownerID() (string, error) {
	p := filepath.Join(os.Getenv("MSB_HOME"), "host-id")
	if b, e := os.ReadFile(p); e == nil {
		return string(b), nil
	}
	if e := os.MkdirAll(filepath.Dir(p), 0700); e != nil {
		return "", e
	}
	b := make([]byte, 16)
	if _, e := rand.Read(b); e != nil {
		return "", e
	}
	id := hex.EncodeToString(b)
	return id, os.WriteFile(p, []byte(id), 0600)
}
func sessionLock(acquire bool) error {
	id, e := ownerID()
	if e != nil {
		return e
	}
	dir := filepath.Join(root, "disks", ".nomad-session")
	owner := filepath.Join(dir, "owner")
	if acquire {
		if e = os.Mkdir(dir, 0700); e == nil {
			return os.WriteFile(owner, []byte(id), 0600)
		}
		b, readErr := os.ReadFile(owner)
		if readErr != nil || string(b) != id {
			return errors.New("this disk has an unfinished session on another computer; stop NOMAD there before moving the drive, or recover the session only after verifying no other writer exists")
		}
		return nil
	}
	b, readErr := os.ReadFile(owner)
	if os.IsNotExist(readErr) {
		return nil
	}
	if readErr != nil {
		return readErr
	}
	if string(b) != id {
		return errors.New("the drive session belongs to a different computer; it has not been unlocked")
	}
	if e = os.Remove(owner); e != nil {
		return e
	}
	return os.Remove(dir)
}

func exists(p string) bool { _, e := os.Stat(p); return e == nil }
func run(args ...string) error {
	c := exec.Command(msb, args...)
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	if logFile != nil {
		c.Stdout = io.MultiWriter(os.Stdout, logFile)
		c.Stderr = io.MultiWriter(os.Stderr, logFile)
	}
	return c.Run()
}
func output(args ...string) ([]byte, error) { return exec.Command(msb, args...).Output() }
func openBrowser() {
	if os.Getenv("NOMAD_NO_BROWSER") == "1" {
		return
	}
	switch runtime.GOOS {
	case "darwin":
		_ = exec.Command("open", dashboard).Start()
	case "windows":
		_ = exec.Command("rundll32", "url.dll,FileProtocolHandler", dashboard).Start()
	default:
		_ = exec.Command("xdg-open", dashboard).Start()
	}
}

func resumePortableApps() error {
	b, e := output("exec", name, "--no-stdin", "--", "cat", "/opt/project-nomad/storage/.portable-running-apps")
	if e != nil {
		return nil
	}
	client := &http.Client{Timeout: 8 * time.Second}
	for _, service := range strings.Fields(string(b)) {
		// Only these default services have audited bind-mounted persistent data.
		if service != "nomad_kiwix_server" && service != "nomad_qdrant" {
			continue
		}
		if _, e = output("exec", name, "--no-stdin", "--", "docker", "container", "inspect", service); e == nil {
			continue
		}
		volumes, e := output("exec", name, "--no-stdin", "--", "docker", "volume", "ls", "-q")
		if e != nil {
			return e
		}
		for _, v := range strings.Fields(string(volumes)) {
			if v == service || strings.HasPrefix(v, service+"_") {
				return fmt.Errorf("%s has a named volume that needs explicit migration; automatic recreation refused", service)
			}
		}
		labelled, e := output("exec", name, "--no-stdin", "--", "docker", "volume", "ls", "-q", "--filter", "label=service="+service)
		if e != nil {
			return e
		}
		if strings.TrimSpace(string(labelled)) != "" {
			return fmt.Errorf("%s has labelled data volumes that need explicit migration", service)
		}
		fmt.Println("Restoring portable service:", service)
		payload, _ := json.Marshal(map[string]string{"service_name": service})
		r, e := client.Post(dashboard+"/api/system/services/force-reinstall", "application/json", strings.NewReader(string(payload)))
		if e != nil {
			return e
		}
		body, _ := io.ReadAll(io.LimitReader(r.Body, 4096))
		r.Body.Close()
		var result struct {
			Success bool   `json:"success"`
			Message string `json:"message"`
		}
		_ = json.Unmarshal(body, &result)
		if r.StatusCode != 200 || !result.Success {
			return fmt.Errorf("could not restore %s: %s", service, result.Message)
		}
		ready := false
		for deadline := time.Now().Add(3 * time.Minute); time.Now().Before(deadline); time.Sleep(2 * time.Second) {
			state, e := output("exec", name, "--no-stdin", "--", "docker", "inspect", "--format", "{{.State.Running}}", service)
			if e == nil && strings.TrimSpace(string(state)) == "true" {
				ready = true
				break
			}
		}
		if !ready {
			return fmt.Errorf("%s did not become ready; check its NOMAD service log", service)
		}
	}
	return nil
}
func configureNativeOllama() {
	client := &http.Client{Timeout: 6 * time.Second}
	r, e := client.Get(dashboard + "/api/ollama/remote-status")
	if e != nil {
		return
	}
	var saved struct {
		Configured bool `json:"configured"`
	}
	e = json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&saved)
	r.Body.Close()
	if r.StatusCode != 200 || e != nil || saved.Configured {
		return
	}
	// First-time setup only: preserve existing backend choices and AI preferences.
	req, _ := http.NewRequest("POST", dashboard+"/api/ollama/configure-remote", strings.NewReader(`{"remoteUrl":"http://host.microsandbox.internal:11434"}`))
	req.Header.Set("Content-Type", "application/json")
	if response, e := client.Do(req); e == nil {
		response.Body.Close()
		if response.StatusCode != 200 {
			fmt.Println("NOMAD is ready; configure native Ollama in AI settings when its server is running.")
		}
	} else {
		fmt.Println("NOMAD is ready; native Ollama did not respond. The library remains available.")
	}
}

func inspect() (string, string) {
	b, e := output("inspect", name, "--format", "json")
	if e != nil {
		return "", ""
	}
	var v struct {
		Status string `json:"status"`
		Config struct {
			Mounts []struct {
				Host  string `json:"host"`
				Guest string `json:"guest"`
			} `json:"mounts"`
		} `json:"config"`
	}
	if json.Unmarshal(b, &v) != nil {
		return "", ""
	}
	host := ""
	for _, m := range v.Config.Mounts {
		if m.Guest == "/opt/project-nomad" {
			host = m.Host
		}
	}
	return v.Status, host
}
func createCache(src, dst string, size int64) error {
	available, e := freeBytes(dst)
	if e != nil {
		return e
	}
	if available < size+(1<<30) {
		return errors.New("insufficient space to reserve the native Docker cache")
	}
	in, e := os.Open(src)
	if e != nil {
		return e
	}
	defer in.Close()
	out, e := os.CreateTemp(filepath.Dir(dst), ".docker-cache-initializing-")
	if e != nil {
		return e
	}
	temp := out.Name()
	defer os.Remove(temp)
	defer out.Close()
	if _, e = io.Copy(out, in); e != nil {
		return e
	}
	if e = out.Truncate(size); e != nil {
		return e
	}
	if e = out.Sync(); e != nil {
		return e
	}
	if e = out.Close(); e != nil {
		return e
	}
	if exists(dst) {
		return errors.New("Docker cache appeared during initialization; refusing to replace it")
	}
	return os.Rename(temp, dst)
}
func mountArgs(data, docker string) []string {
	args := []string{"--cpus", "6", "--memory", "8G", "--mount-disk", data + ":/opt/project-nomad:format=" + storage.Format + ",fstype=ext4", "--mount-disk", docker + ":/var/lib/docker:format=" + storage.Format + ",fstype=ext4", "--net-default", "deny", "--net-rule", "allow:ingress@127.0.0.1", "--net-rule", "allow@public", "--net-rule", "allow@dns", "--net-rule", "allow@host:tcp:11434"}
	for _, p := range []string{"8080", "8090", "8100", "8200", "8310", "8311", "8400", "8410", "8420", "8430", "8440", "8450", "8460", "8470", "8480", "8490", "8500", "9999"} {
		args = append(args, "--port", "127.0.0.1:"+p+":"+p)
	}
	return args
}
func start() error {
	guard, err := net.Listen("tcp", "127.0.0.1:51987")
	if err != nil {
		fmt.Println("NOMAD is already starting. Please wait for the dashboard to open.")
		return nil
	}
	defer guard.Close()
	data, err := portablePath(storage.Data)
	if err != nil {
		return err
	}
	docker, err := portablePath(strings.ReplaceAll(storage.DockerPattern, "{arch}", runtime.GOARCH))
	if err != nil {
		return err
	}
	if !exists(data) {
		return errors.New("NOMAD data disk is missing; restore it from backup")
	}
	if e := sessionLock(true); e != nil {
		return e
	}
	archive := filepath.Join(root, "runtime", "ubuntu-"+runtime.GOARCH+".msb")
	status, bound := inspect()
	if strings.EqualFold(status, "running") && bound == data {
		if r, e := (&http.Client{Timeout: 2 * time.Second}).Get(dashboard + "/api/health"); e == nil {
			r.Body.Close()
			if r.StatusCode == 200 {
				if e := resumePortableApps(); e != nil {
					return e
				}
				configureNativeOllama()
				fmt.Println("NOMAD is already running: " + dashboard)
				openBrowser()
				return nil
			}
		}
	}
	fmt.Println("Checking portable runtime artifacts...")
	if e := verifyArtifacts(!exists(docker), status == "" || bound != data); e != nil {
		return e
	}
	if !exists(docker) {
		fmt.Println("Preparing the native Docker cache (first use only)...")
		seed, e := portablePath(storage.Seed)
		if e != nil {
			return e
		}
		if e := createCache(seed, docker, storage.DockerGiB<<30); e != nil {
			return e
		}
	}
	if !strings.EqualFold(status, "running") {
		probe, e := net.Listen("tcp", "127.0.0.1:8080")
		if e != nil {
			return errors.New("dashboard port 8080 is already in use; close that local service before starting NOMAD")
		}
		probe.Close()
	}
	if status != "" && bound != data {
		if strings.EqualFold(status, "running") {
			return errors.New("NOMAD is running with a different disk path; use Stop NOMAD before relocating the disk")
		}
		if !exists(archive) {
			return errors.New("runtime recovery archive is missing; refusing to discard the existing runtime")
		}
		fmt.Println("Rebinding the stopped Ubuntu runtime to this disk location.")
		if e := run("remove", name); e != nil {
			return e
		}
		status = ""
	}
	if status == "" {
		fmt.Println("Preparing Ubuntu for this computer. First use needs internet access.")
		var args []string
		if exists(archive) {
			args = []string{"restore", archive, "--name", name}
		} else {
			args = []string{"create", "ubuntu:24.04", "--name", name, "--root-disk", "32G"}
		}
		args = append(args, mountArgs(data, docker)...)
		if e := run(args...); e != nil {
			return e
		}
	} else if !strings.EqualFold(status, "running") {
		if e := run("start", name); e != nil {
			return e
		}
	}
	for _, script := range []string{"bootstrap-ubuntu.sh", "guest-start.sh"} {
		if e := run("copy", filepath.Join(root, script), name+":/root/"+script); e != nil {
			return e
		}
	}
	fmt.Println("Checking Ubuntu and Docker dependencies...")
	if e := run("exec", name, "--stream", "--no-stdin", "--", "bash", "/root/bootstrap-ubuntu.sh"); e != nil {
		return e
	}
	if !exists(archive) {
		if e := run("snapshot", "create", "ubuntu-ready", "--sandbox", name); e != nil {
			return e
		}
		if e := run("snapshot", "export", name+":ubuntu-ready", "--with-image", "--output", archive); e != nil {
			return e
		}
	}
	// A running native Ollama service is reused, never rebound or reconfigured.
	resp, e := (&http.Client{Timeout: 2 * time.Second}).Get("http://127.0.0.1:11434/api/tags")
	if e == nil {
		resp.Body.Close()
	} else if runtime.GOOS == "darwin" {
		fmt.Println("Starting the installed Ollama application...")
		_ = exec.Command("open", "-a", "Ollama").Run()
	}
	fmt.Println("Starting NOMAD. The first native image build can take several minutes.")
	if e := run("exec", name, "--stream", "--no-stdin", "--", "bash", "/root/guest-start.sh"); e != nil {
		return e
	}
	client := &http.Client{Timeout: 4 * time.Second}
	for deadline := time.Now().Add(4 * time.Minute); time.Now().Before(deadline); time.Sleep(2 * time.Second) {
		resp, e := client.Get(dashboard + "/api/health")
		if e == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				if e := resumePortableApps(); e != nil {
					return e
				}
				configureNativeOllama()
				fmt.Println("NOMAD is ready: " + dashboard + "\nUse Stop NOMAD before ejecting the disk.")
				openBrowser()
				return nil
			}
		}
	}
	return errors.New("NOMAD did not become healthy; see the host launch.log and NOMAD service logs")
}
func stop() error {
	guard, e := net.Listen("tcp", "127.0.0.1:51987")
	if e != nil {
		return errors.New("NOMAD is still starting; wait for startup to finish before stopping or ejecting the disk")
	}
	defer guard.Close()
	return stopCore()
}

func stopCore() error {
	status, _ := inspect()
	if status == "" || !strings.EqualFold(status, "running") {
		if e := sessionLock(false); e != nil {
			return e
		}
		fmt.Println("NOMAD is already stopped.")
		return nil
	}
	fmt.Println("Stopping NOMAD containers and flushing the external disks...")
	if e := run("exec", name, "--stream", "--no-stdin", "--", "bash", "-lc", guestStopScript); e != nil {
		return e
	}
	if e := run("stop", name); e != nil {
		return e
	}
	if e := sessionLock(false); e != nil {
		return e
	}
	fmt.Println("NOMAD is stopped. You can now eject the Samsung X5.")
	return nil
}
func runtimeName(workspace string) (string, error) {
	data, err := os.ReadFile(filepath.Join(workspace, "runtime-id"))
	if os.IsNotExist(err) {
		return "nomad-x5", nil
	}
	if err != nil {
		return "", err
	}
	value := strings.TrimSpace(string(data))
	if !strings.HasPrefix(value, "nomad-") || len(value) <= len("nomad-") || len(value) > 64 {
		return "", errors.New("invalid workspace runtime-id")
	}
	for _, character := range value {
		if character != '-' && (character < 'a' || character > 'z') && (character < '0' || character > '9') {
			return "", errors.New("invalid workspace runtime-id")
		}
	}
	return value, nil
}

func mainError() error {
	exe, e := os.Executable()
	if e != nil {
		return e
	}
	root = filepath.Dir(exe)
	for i := 0; i < 5 && !exists(filepath.Join(root, "bootstrap-ubuntu.sh")); i++ {
		if exists(filepath.Join(root, "Project-NOMAD", "bootstrap-ubuntu.sh")) {
			root = filepath.Join(root, "Project-NOMAD")
			break
		}
		root = filepath.Dir(root)
	}
	if !exists(filepath.Join(root, "bootstrap-ubuntu.sh")) {
		return errors.New("keep the launcher inside the Project-NOMAD folder on the external drive")
	}
	name, e = runtimeName(root)
	if e != nil {
		return e
	}
	b, e := os.ReadFile(filepath.Join(root, "storage.json"))
	if e != nil {
		return e
	}
	if e = json.Unmarshal(b, &storage); e != nil {
		return e
	}
	if storage.Version != 1 || storage.Format != "raw" || storage.DockerGiB < 8 {
		return errors.New("unsupported portable storage manifest")
	}
	if runtime.GOARCH != "arm64" && runtime.GOARCH != "amd64" {
		return errors.New("this runtime supports ARM64 and x86-64 computers")
	}
	home, e := os.UserHomeDir()
	if e != nil {
		return e
	}
	if os.Getenv("MSB_HOME") == "" {
		_ = os.Setenv("MSB_HOME", filepath.Join(home, ".microsandbox-nomad"))
	}
	if e = os.MkdirAll(os.Getenv("MSB_HOME"), 0700); e != nil {
		return e
	}
	logFile, _ = os.OpenFile(filepath.Join(os.Getenv("MSB_HOME"), "launch.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if logFile != nil {
		defer logFile.Close()
		fmt.Fprintln(logFile, "\nNOMAD launcher", time.Now().Format(time.RFC3339), runtime.GOOS, runtime.GOARCH)
	}
	candidates := []string{"msb", filepath.Join(home, ".local", "bin", "msb"), filepath.Join(home, ".microsandbox", "bin", "msb"), "/opt/homebrew/bin/msb", "/usr/local/bin/msb"}
	if runtime.GOOS == "windows" {
		candidates = append([]string{"msb.exe"}, candidates...)
		candidates = append(candidates, filepath.Join(home, ".local", "bin", "msb.exe"), filepath.Join(home, ".microsandbox", "bin", "msb.exe"))
	}
	for _, p := range candidates {
		if found, e := exec.LookPath(p); e == nil {
			if runtime.GOOS == "windows" && !strings.EqualFold(filepath.Ext(found), ".exe") {
				continue
			}
			msb = found
			break
		}
	}
	if msb == "" {
		return errors.New("install microsandbox 0.7.13 or newer on this computer first: https://microsandbox.dev")
	}
	action := "start"
	if strings.Contains(strings.ToLower(filepath.Base(exe)), "stop") {
		action = "stop"
	}
	if len(os.Args) > 1 {
		action = os.Args[1]
	}
	if runtime.GOOS == "windows" && runtime.GOARCH == "amd64" && strings.Contains(strings.ToLower(os.Getenv("PROCESSOR_ARCHITEW6432")+os.Getenv("PROCESSOR_ARCHITECTURE")), "arm64") {
		args := []string{action}
		if len(os.Args) > 2 {
			args = append(args, os.Args[2:]...)
		}
		c := exec.Command(filepath.Join(root, "bin", "windows-arm64", "nomad.exe"), args...)
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		return c.Run()
	}
	switch action {
	case "start":
		return start()
	case "stop":
		return stop()
	case "status":
		return run("inspect", name)
	case "grow":
		if len(os.Args) != 3 {
			return errors.New("usage: nomad grow SIZE_IN_GIB")
		}
		n, e := strconv.ParseInt(os.Args[2], 10, 32)
		if e != nil || n < 1 {
			return errors.New("growth size must be a positive integer in GiB")
		}
		p, e := portablePath(storage.Data)
		if e != nil {
			return e
		}
		info, e := os.Stat(p)
		if e != nil {
			return e
		}
		if n<<30 <= info.Size() {
			return errors.New("grow only enlarges the content disk; shrinking is not supported")
		}
		guard, e := net.Listen("tcp", "127.0.0.1:51987")
		if e != nil {
			return errors.New("NOMAD startup or shutdown is in progress; wait before resizing")
		}
		defer guard.Close()
		available, e := freeBytes(p)
		if e != nil {
			return fmt.Errorf("cannot verify free space: %w", e)
		}
		if available < (n<<30-info.Size())+(1<<30) {
			return errors.New("insufficient free space to reserve the larger raw image and retain 1 GiB headroom")
		}
		if e = stopCore(); e != nil {
			return e
		}
		f, e := os.OpenFile(p, os.O_RDWR, 0600)
		if e != nil {
			return e
		}
		defer f.Close()
		if e = f.Truncate(n << 30); e != nil {
			return e
		}
		if e = f.Sync(); e != nil {
			return e
		}
		fmt.Printf("Content image expanded to %d GiB. Start NOMAD to extend ext4.\n", n)
		return nil
	default:
		return errors.New("usage: nomad [start|stop|status|grow SIZE_IN_GIB]")
	}
}
func main() {
	if e := mainError(); e != nil {
		fmt.Fprintln(os.Stderr, "NOMAD:", e)
		if runtime.GOOS == "windows" {
			fmt.Println("Press Enter to close.")
			fmt.Scanln()
		}
		os.Exit(1)
	}
}
