# Validation

Validated on an Apple Silicon Mac with microsandbox 0.7.13 and NOMAD 1.35.1, pinned to revision 54ee30a44902e5c252b477f8685c26ec3064ab72.

- Copied an existing, stopped installation from an exFAT external SSD to internal storage.
- Compared all 58 copied files byte for byte: 346.1 GiB matched.
- Kept both native app bundles inside the installation, using Launchers/Project-NOMAD -> .. for the original launcher layout.
- Rebound the stopped Ubuntu sandbox using the existing launcher.
- Confirmed both raw data mounts point into the home-directory installation.
- Confirmed the dashboard health endpoint returns HTTP 200 and managed apps resume.

The clean-install instructions derive from the original prototype build recipe. A fresh installation from this public repository has not been run end to end. Intel Macs, Linux and Windows are outside this repository’s tested path. The GUI packaging adjustment is compilation-checked separately. No populated data image, host state or private logs are distributed.
