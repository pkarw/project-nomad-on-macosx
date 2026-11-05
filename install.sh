#!/bin/sh
# Keep execution inside main so curl | sh receives the complete script first.
set -eu

fail() { printf '\n❌ %s\n' "$*" >&2; exit 1; }
step() { printf '\n🧭 %s\n' "$*"; }

main() {
    destination=${NOMAD_INSTALL_DIR:-"$HOME/Project-NOMAD"}
    check_only=0
    start_after_install=1
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h)
                printf '%s\n' 'Usage: sh install.sh [--dir PATH] [--check] [--no-start]' \
                    'Installs into ~/Project-NOMAD by default.' \
                    '--dir PATH selects the installation directory (absolute path).' \
                    'NOMAD_INSTALL_DIR is also supported; --dir takes precedence.' \
                    '--check checks prerequisites without changing anything.' \
                    '--no-start installs without launching NOMAD.'
                return ;;
            --dir)
                [ "$#" -ge 2 ] || fail '--dir requires an absolute directory path.'
                case "$2" in ''|--*) fail '--dir requires an absolute directory path.' ;; esac
                destination=$2
                shift ;;
            --dir=*) destination=${1#--dir=} ;;
            --check) check_only=1 ;;
            --no-start) start_after_install=0 ;;
            *) fail "Unknown option: $1" ;;
        esac
        shift
    done
    [ "$(uname -s)" = Darwin ] || fail 'This installer requires macOS.'
    [ "$(uname -m)" = arm64 ] || fail 'This installer requires an Apple Silicon Mac.'
    [ "$(id -u)" != 0 ] || fail 'Run as your normal user, without sudo.'
    case "$destination" in /*) ;; *) fail 'Installation directory must be an absolute path.' ;; esac
    [ ! -e "$destination" ] && [ ! -L "$destination" ] || fail "Destination already exists; nothing was changed: $destination"
    parent=$(dirname "$destination")
    [ -d "$parent" ] && [ -w "$parent" ] || fail "Destination parent must exist and be writable: $parent"
    shortcut_suffix=""
    if [ "$destination" != "$HOME/Project-NOMAD" ]; then
        shortcut_suffix=" ($(basename "$destination"))"
    fi
    for base_name in NOMAD 'Stop NOMAD'; do
        alias_name="$base_name$shortcut_suffix"
        [ ! -e "$HOME/Desktop/$alias_name" ] && [ ! -L "$HOME/Desktop/$alias_name" ] || fail "Desktop shortcut already exists: $alias_name"
    done
    available=$(df -Pk "$parent" | awk 'END {print $4}')
    [ "$available" -ge 419430400 ] || fail 'At least 400 GiB of free space is required.'
    export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.microsandbox/bin"
    if [ "$check_only" = 1 ]; then
        xcrun --find swiftc >/dev/null 2>&1 || fail 'Install Apple Command Line Tools: xcode-select --install'
        command -v python3 >/dev/null 2>&1 || fail 'Python 3 is required.'
        command -v msb >/dev/null 2>&1 || fail 'microsandbox is required: brew install superradcompany/tap/microsandbox'
        msb --version
        step 'Preflight passed. No files or services were changed.'
        return
    fi
    if ! xcrun --find swiftc >/dev/null 2>&1; then
        xcode-select --install || true
        fail 'Finish installing Apple Command Line Tools, then run this installer again.'
    fi
    if ! command -v msb >/dev/null 2>&1; then
        command -v brew >/dev/null 2>&1 || fail 'Install Homebrew from https://brew.sh, then rerun this installer.'
        step 'Installing microsandbox'
        brew install superradcompany/tap/microsandbox </dev/null
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        command -v brew >/dev/null 2>&1 || fail 'Python 3 is required; install it and rerun.'
        brew install python </dev/null
    fi
    msb --version
    staging=$(mktemp -d "$parent/.nomad-install.XXXXXX")
    builder=$(mktemp -d /tmp/nm.XXXXXX)
    complete=0
    trap 'on_exit' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    step 'Downloading the macOS adapter'
    curl -fL --retry 3 https://github.com/pkarw/project-nomad-on-macosx/archive/refs/heads/main.tar.gz -o "$staging/source.tar.gz" </dev/null
    mkdir "$staging/workspace"
    tar -xzf "$staging/source.tar.gz" --strip-components=1 -C "$staging/workspace"
    workspace="$staging/workspace"
    python3 - "$workspace" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
for name, expected in json.loads((root / 'checksums-source.json').read_text()).items():
    if hashlib.sha256((root / name).read_bytes()).hexdigest() != expected:
        raise SystemExit('Source checksum mismatch: ' + name)
expected = (root / 'bin/darwin-arm64/SHA256SUMS').read_text().split()[0]
if hashlib.sha256((root / 'bin/darwin-arm64/nomad').read_bytes()).hexdigest() != expected:
    raise SystemExit('Launcher checksum mismatch')
PY
    chmod +x "$workspace/bin/darwin-arm64/nomad"
    mkdir -p "$workspace/disks" "$workspace/runtime"
    step 'Creating clean Linux disks in an isolated temporary VM'
    MSB_HOME="$builder" msb create ubuntu:24.04 --name nomad-image-builder --root-disk 4G --memory 1G \
        --mount-named seed-data:/seed-data:kind=disk,size=256G \
        --mount-named seed-docker:/seed-docker:kind=disk,size=8G </dev/null
    MSB_HOME="$builder" msb exec nomad-image-builder --no-stdin -- bash -c '
set -euo pipefail
for target in /seed-data /seed-docker; do
    mountpoint -q "$target"
    device=$(findmnt -n -o SOURCE --target "$target")
    case "$device" in /dev/vd*) ;; *) echo "Unexpected seed device" >&2; exit 1 ;; esac
    test "$device" != "$(findmnt -n -o SOURCE /)"
    umount "$target"
    mkfs.ext4 -F -m 0 -E lazy_itable_init=0,lazy_journal_init=0 "$device"
    e2fsck -fn "$device"
done
' </dev/null
    MSB_HOME="$builder" msb stop nomad-image-builder </dev/null
    step 'Installing the clean disk images (this may take several minutes)'
    copy_disk "$builder/volumes/seed-data/disk.raw" "$workspace/disks/nomad-data.img"
    copy_disk "$builder/volumes/seed-docker/disk.raw" "$workspace/disks/docker-empty.img"
    step 'Generating the artifact manifest'
    python3 - "$workspace" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
checksums = {}
for name in ['storage.json', 'bootstrap-ubuntu.sh', 'guest-start.sh', 'release.json', 'disks/docker-empty.img']:
    digest = hashlib.sha256()
    with (root / name).open('rb') as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            digest.update(block)
    checksums[name] = digest.hexdigest()
(root / 'release-checksums.json').write_text(json.dumps(checksums, indent=2) + '\n')
PY
    step 'Building the native Start and Stop apps'
    bash "$workspace/macos/build-apps.sh" </dev/null
    MSB_HOME="$builder" msb remove nomad-image-builder </dev/null
    MSB_HOME="$builder" msb volume remove seed-data seed-docker </dev/null
    rm -rf "$builder"
    # Recheck just before the final move; never merge into an existing workspace.
    [ ! -e "$destination" ] && [ ! -L "$destination" ] || fail "Destination appeared during installation: $destination"
    mv "$workspace" "$destination"
    step 'Adding Desktop shortcuts'
    swift - "$destination" "$HOME/Desktop" "$shortcut_suffix" <<'SWIFT'
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let desktop = URL(fileURLWithPath: CommandLine.arguments[2])
let suffix = CommandLine.arguments[3]
try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
for name in ["NOMAD", "Stop NOMAD"] {
    let target = root.appendingPathComponent("Launchers/\(name).app")
    let alias = desktop.appendingPathComponent(name + suffix)
    guard !FileManager.default.fileExists(atPath: alias.path) else {
        fatalError("Desktop shortcut already exists: \(alias.path)")
    }
    let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
    try URL.writeBookmarkData(bookmark, to: alias)
}
SWIFT
    complete=1
    rm -rf "$staging"
    step "Installed in $destination"
    if [ "$start_after_install" = 1 ]; then
        step 'Starting NOMAD — initial downloads and native image builds can take a while'
        "$destination/Launchers/Project-NOMAD/bin/darwin-arm64/nomad" start </dev/null
    fi
    printf '\n✅ Ready. Desktop shortcuts: NOMAD%s and Stop NOMAD%s.\n' "$shortcut_suffix" "$shortcut_suffix"
}

copy_disk() {
    # APFS clones avoid duplicating the large clean images. Other filesystems copy normally.
    if ! cp -c "$1" "$2" 2>/dev/null; then
        rm -f "$2"
        cp "$1" "$2"
    fi
}

on_exit() {
    result=$?
    if [ "$complete" = 0 ]; then
        MSB_HOME="$builder" msb stop nomad-image-builder --timeout 20 </dev/null >/dev/null 2>&1 || true
        printf '\n⚠️ Installation did not finish. Recovery files: %s; builder: %s\n' "$staging" "$builder" >&2
        if [ -d "$destination" ]; then
            printf 'Workspace installed at %s; fix the reported error and launch its NOMAD app.\n' "$destination" >&2
        fi
    fi
    exit "$result"
}

main "$@"
