# 🧭 Project NOMAD on MacosX

### Your offline knowledge library. On your Mac. No external drive required. 🍎

Run [Project NOMAD](https://github.com/Crosstalk-Solutions/project-nomad) in an Ubuntu microVM powered by [microsandbox](https://github.com/superradcompany/microsandbox), with native macOS Start/Stop apps and optional host-native Ollama for Apple GPU inference.

**Community prototype · Apple Silicon · macOS · Tested with microsandbox 0.7.13**

- ✅ Internal SSD or external storage
- ✅ Everything in one `~/Project-NOMAD` folder, with Desktop shortcuts
- ✅ Docker runs inside Ubuntu; Docker Desktop is not required
- ✅ Existing library, settings and databases survive relocation
- ✅ Browser dashboard at **http://localhost:8080**

> The short path is moving an existing working installation: stop → copy → add shortcuts → start. A fresh setup needs empty Linux disk images and initial downloads/builds. This repository contains the adapter and tutorial, not a populated offline library.

## ⚡ Choose your path

- **Already have a working portable installation?** Follow [Move it onto your Mac](#-move-an-existing-installation-onto-your-mac).
- **Starting from scratch?** Follow [Fresh setup](#-fresh-setup).
- **Just using it day to day?** Double-click **NOMAD** on your Desktop. Use **Stop NOMAD** when finished.

## 🧠 How it works

```text
macOS / Apple Silicon
├── NOMAD.app → Go launcher → microsandbox → Ubuntu 24.04
│                                          └── Docker → NOMAD + apps
├── ~/Project-NOMAD/disks/nomad-data.img     ← library, settings, databases
├── ~/Project-NOMAD/disks/docker-arm64.img   ← Docker images/cache
└── native Ollama                           ← optional Apple GPU inference
```

The guest sees real ext4 filesystems inside raw disk-image files. macOS stores those files on its internal disk or an external drive. Host runtime metadata lives in `~/.microsandbox-nomad`; downloaded Ollama models remain in Ollama’s own storage.

## 📦 Requirements

- Apple Silicon Mac (M1 or newer); Intel Macs are untested here.
- Enough RAM for the launcher’s **8 GiB Ubuntu guest**, plus macOS and optional AI models.
- **At least 400 GB free for the default workspace**, plus temporary builder space for a fresh install. Content disk: 256 GiB; per-architecture Docker cache: 64 GiB; clean Docker seed: 8 GiB. Allow extra room for VM state and downloads.
- Internet for the initial runtime, images, builds, models and knowledge downloads. Offline use requires downloading your chosen content first.
- [Homebrew](https://brew.sh), Python 3, and Apple Command Line Tools (`xcode-select --install`).

Install microsandbox using its [official instructions](https://github.com/superradcompany/microsandbox#readme):

```bash
brew install superradcompany/tap/microsandbox
msb --version
```

The tested version is **0.7.13**; newer versions may change CLI behavior. Optional AI: install [Ollama](https://ollama.com), run it and download a model that fits your Mac.

## 🚚 Move an existing installation onto your Mac

This is the path validated on a real Mac: **346.1 GiB copied and verified byte for byte**, then the dashboard returned HTTP 200 using internal-disk mounts.

### 1️⃣ Stop the external installation

Use its **Stop NOMAD.app** and wait for completion. Copying a running database disk is not a consistent backup. Leave the original drive intact.

### 2️⃣ Copy the workspace and apps

Replace `YOUR_DRIVE` below with your drive’s name. The destination must not already exist; do not merge two installations.

```bash
SOURCE="/Volumes/YOUR_DRIVE"
test ! -e "$HOME/Project-NOMAD" &&
  cp -pR "$SOURCE/Project-NOMAD" "$HOME/Project-NOMAD"
```

Continue only after the copy finishes successfully:

```bash
mkdir -p "$HOME/Project-NOMAD/Launchers"
cp -pR "$SOURCE/NOMAD.app" "$SOURCE/Stop NOMAD.app" "$HOME/Project-NOMAD/Launchers/"
ln -s .. "$HOME/Project-NOMAD/Launchers/Project-NOMAD"
```

That relative link lets the original app bundles find the workspace while keeping both apps inside the project folder. If your source already has `Launchers/`, copying the workspace preserves that layout; skip copying the apps and creating the link again.

For an independent content check before first start (this reads the entire library):

```bash
diff -qr "$SOURCE/Project-NOMAD/disks" "$HOME/Project-NOMAD/disks"
```

No output means the disk files match. A large copy/check can take several minutes.

### 3️⃣ Add Desktop shortcuts

In Finder, open `~/Project-NOMAD/Launchers`. For **NOMAD.app** and **Stop NOMAD.app**, choose **File → Make Alias**, then move the aliases to the Desktop. Keep the original apps in `Launchers/`.

### 4️⃣ Start the local copy

Double-click the Desktop **NOMAD** shortcut. The launcher reconnects the stopped runtime to the new disk paths and opens the dashboard when ready.

Check the mounts:

```bash
"$HOME/Project-NOMAD/bin/darwin-arm64/nomad" status
curl --fail http://localhost:8080/api/health
```

Both data mounts should point under your home folder, not `/Volumes/…`. Once healthy, the external drive can be disconnected. 🎉

## 🌱 Fresh setup

This path reconstructs the prototype from clean disks. It is a developer recipe, not a one-click installer; it has **not been rerun end to end from this public repo**. See [validation](docs/VALIDATION.md).

### 1️⃣ Download the adapter

```bash
git clone https://github.com/pkarw/project-nomad-on-macosx.git "$HOME/Project-NOMAD"
cd "$HOME/Project-NOMAD"
mkdir -p disks runtime
```

The repository includes the original tested Apple Silicon Go launcher and its source. To rebuild it yourself, install Go 1.22+ and run:

```bash
(cd launcher && go build -trimpath -o ../bin/darwin-arm64/nomad .)
```

### 2️⃣ Create clean ext4 seed disks

Use a separate builder context on your Mac’s native filesystem. These commands create a new sandbox and format **only its two newly created seed volumes**. Do not substitute devices from an existing installation.

```bash
export MSB_HOME="$PWD/.nomad-builder"
msb create ubuntu:24.04 --name nomad-image-builder --root-disk 4G --memory 1G \
  --mount-named seed-data:/seed-data:kind=disk,size=256G \
  --mount-named seed-docker:/seed-docker:kind=disk,size=8G

msb exec nomad-image-builder --no-stdin -- bash -c '
set -euo pipefail
for target in /seed-data /seed-docker; do
  device=$(findmnt -n -o SOURCE --target "$target")
  case "$device" in /dev/vd*) ;; *) echo "Unexpected seed device" >&2; exit 1 ;; esac
  test "$device" != "$(findmnt -n -o SOURCE /)"
  umount "$target"
  mkfs.ext4 -F -m 0 -E lazy_itable_init=0,lazy_journal_init=0 "$device"
  e2fsck -fn "$device"
done
'
msb stop nomad-image-builder
```

Only after the builder stops successfully, copy the clean raw volumes:

```bash
cp -n "$MSB_HOME/volumes/seed-data/disk.raw" disks/nomad-data.img
cp -n "$MSB_HOME/volumes/seed-docker/disk.raw" disks/docker-empty.img
unset MSB_HOME
```

The normal launcher uses `~/.microsandbox-nomad`, separate from the builder. Retain the stopped builder until the installation is verified. Raw images can consume their full logical capacity, especially on exFAT.

### 3️⃣ Generate the local artifact manifest

The launcher checks its immutable setup artifacts. Generate checksums for your own clean seed; mutable application data is excluded.

```bash
python3 - <<'PY'
import hashlib, json
from pathlib import Path
files = ['storage.json', 'bootstrap-ubuntu.sh', 'guest-start.sh',
         'release.json', 'disks/docker-empty.img']
checksums = {}
for name in files:
    digest = hashlib.sha256()
    with Path(name).open('rb') as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            digest.update(block)
    checksums[name] = digest.hexdigest()
Path('release-checksums.json').write_text(json.dumps(checksums, indent=2) + '\n')
PY
```

These locally generated hashes detect later accidental changes; they do not authenticate the download. `checksums-source.json` records the packaged source artifact hashes.

### 4️⃣ Build the macOS apps

```bash
bash macos/build-apps.sh
open Launchers
```

This builds locally ad-hoc-signed apps, puts them in `Launchers/`, and adds the compatibility link. Make Finder aliases on the Desktop as described above. The apps are not notarized; inspect the source before using macOS’s per-app **Open** approval if requested.

### 5️⃣ Launch! 🚀

Open `Launchers/NOMAD.app`. First use provisions Ubuntu and Docker, downloads pinned NOMAD source, builds native images and starts the services. This can take several minutes or longer depending on your connection and Mac.

When ready: **http://localhost:8080**. Install your chosen apps and download knowledge before going offline. For Kiwix content, enable **Information Library (Kiwix)** in NOMAD.

## 🤖 Native AI on your Mac

The adapter reuses host-native Ollama so inference can use Apple’s GPU. It connects through NOMAD’s existing remote-Ollama feature at:

```text
http://host.microsandbox.internal:11434
```

Existing AI configuration is preserved. Run Ollama and download your model on the host first. The adapter does not move your models into the VM or stop Ollama when NOMAD stops.

## 🛑 Stop, back up, move

- **Stop:** use the Desktop **Stop NOMAD** shortcut; wait for completion.
- **Backup:** while stopped, copy `disks/nomad-data.img` to another physical disk and verify its checksum. Keep the compatible adapter version too. Back up host Ollama models separately if needed.
- **Move:** stop → copy → verify → start. Never run two writers against the same images.
- **Grow:** after a verified backup, `./bin/darwin-arm64/nomad grow 512` enlarges the content disk to 512 GiB. Shrinking is unsupported.

## 🔧 Troubleshooting

| Symptom | Next step |
| --- | --- |
| Dashboard unavailable | Wait for first-build completion; inspect `~/.microsandbox-nomad/gui-start.log` and `launch.log`. |
| Port 8080 is busy | Stop the other service before launching NOMAD. |
| Session belongs to another host | Stop NOMAD on that host; do not delete the marker while any writer might exist. |
| Apps cannot find the workspace | Keep both apps in `Launchers/` and its `Project-NOMAD -> ..` link intact. |
| AI has no models | Start host Ollama, download a model and check the remote endpoint in AI settings. |
| An update changes behavior | This prototype pins NOMAD source and disables automatic core updater startup. Update the adapter deliberately. |

## 🧪 Tested scope

The working deployment used **NOMAD 1.35.1**, revision `54ee30a44902e5c252b477f8685c26ec3064ab72`, **Ubuntu 24.04** and **microsandbox 0.7.13**. Internal-SSD relocation and dashboard health were checked on Apple Silicon. Startup timing varies; the first install is not instant. Other platforms are not claimed as validated here.

See [validation](docs/VALIDATION.md), [original reproduction notes](docs/REPRODUCE.md) and [release metadata](release.json).

## 🙌 Credits & license

Built around [Project NOMAD by Crosstalk Solutions](https://github.com/Crosstalk-Solutions/project-nomad) and [microsandbox](https://github.com/superradcompany/microsandbox), both Apache-2.0 projects. This is an independent community adapter, not an official macOS release. Adapter code is MIT licensed; upstream projects retain their own licenses. No personal library, credentials, models, database images or runtime archives are included.
