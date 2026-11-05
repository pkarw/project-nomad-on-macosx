# Reproduce the portable prototype

This is a developer recipe for a macOS Apple Silicon or Linux release-building host. End users use the prebuilt launchers. Windows runtime validation is a separate acceptance task.

Prerequisites: microsandbox 0.7.13+, a working virtualization backend, Go, and `qemu-img`. The local Mac packaging run used Docker Desktop's bundled `qemu-img`. Runtime users do not need Docker Desktop or host Docker: Docker runs inside Ubuntu.

## 1. Prepare the drive

Use an existing writable exFAT volume. Never erase a user's drive as part of this procedure. Create `Project-NOMAD/disks` and copy the source scripts, launcher, assets, and documentation there.

Set `MSB_HOME` to a temporary directory on the **builder's native filesystem**, not on exFAT. Create a temporary Ubuntu 24.04 builder with a small managed root and two empty disk-backed named volumes: 256 GiB mounted at `/seed-data` and 8 GiB mounted at `/seed-docker`.

```sh
msb create ubuntu:24.04 --name nomad-image-builder --root-disk 4G \
  --mount-named seed-data:/seed-data:kind=disk,size=256G \
  --mount-named seed-docker:/seed-docker:kind=disk,size=8G
```

Inside that temporary guest, identify the two devices from `/proc/mounts`, unmount those **seed volumes**, and format them with Ubuntu's `mkfs.ext4`:

```sh
mkfs.ext4 -F -m 0 -E lazy_itable_init=0,lazy_journal_init=0 DEVICE
```

Run `e2fsck -fn DEVICE` on each unmounted volume, then stop the builder. The local validation found filesystem errors in the QCOW2 path even after native formatting; neither formatting nor a small successful fixture established reliability. The selected runtime format is raw, and its full workload must pass independently. The original failure's root cause remains unproven.

## 2. Convert the clean seed disks

On the host, after the builder has stopped:

```sh
qemu-img convert -f raw -O raw "$MSB_HOME/volumes/seed-data/disk.raw" DRIVE/Project-NOMAD/disks/nomad-data.img
qemu-img convert -f raw -O raw "$MSB_HOME/volumes/seed-docker/disk.raw" DRIVE/Project-NOMAD/disks/docker-empty.img
```

Replace `DRIVE` with the actual exFAT mount path. These raw files reserve their full capacity on exFAT; provisioning the 256 GiB data file can take several minutes. The launcher copies the 8 GiB seed to a new architecture-specific raw Docker image, enlarges its file to 64 GiB, and lets the guest extend ext4 before Docker starts. Include the versioned `storage.json` configuration. The normal runtime must use a separate host-local `MSB_HOME`, not the temporary builder context.

## 3. Build and package

Run `launcher/build.sh`; it cross-compiles standard-library-only Go launchers for Apple Silicon macOS, Linux x86-64/ARM64, and Windows x86-64/ARM64. The Windows `.syso` files embed the custom icon; regenerate using `rsrc` and the supplied `.ico` when changing it. Package the macOS app bundles and Linux icon installer alongside `Project-NOMAD`.

Generate `release-checksums.json`, mapping relative paths to SHA-256 hex digests for `storage.json`, `bootstrap-ubuntu.sh`, `guest-start.sh`, `disks/docker-empty.img`, and any bundled clean `runtime/ubuntu-<arch>.msb` archive. Exclude mutable data disks, architecture caches, and host logs. This detects accidental artifact changes; it is not a substitute for signed release verification.

On first launch, the adapter provisions Ubuntu, installs Docker and pinned NOMAD source, exports a clean dependency archive for that CPU architecture, builds the native NOMAD images, starts the existing Compose services, and connects native Ollama through the existing API. First use needs internet; provision both CPU architectures before claiming an offline cross-architecture package.

## 4. Validate before sharing

Follow the specification and validation record. At minimum, verify application health, model discovery, a complete cold restart, filesystem checks after the full build, single-writer behavior, updater disablement, grow-only capacity extension, and a stopped-disk backup/restore. Shutdown must explicitly unmount both external filesystems before stopping the VM. Validate Linux and Windows on actual hosts before claiming those targets work. Do not distribute the populated application image, Docker diagnostic caches, personal models, credentials, or host state as a source contribution.
