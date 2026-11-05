# Validation

Validated on an Apple Silicon Mac with microsandbox 0.7.13 and NOMAD 1.35.1, pinned to revision 54ee30a44902e5c252b477f8685c26ec3064ab72.

- Copied an existing, stopped installation from an exFAT external SSD to internal storage.
- Compared all 58 copied files byte for byte: 346.1 GiB matched.
- Kept both native app bundles inside the installation, using Launchers/Project-NOMAD -> .. for the original launcher layout.
- Rebound the stopped Ubuntu sandbox using the existing launcher.
- Confirmed both raw data mounts point into the home-directory installation.
- Confirmed the dashboard health endpoint returns HTTP 200 and managed apps resume.

The clean-install instructions derive from the original prototype build recipe. A fresh installation from this public repository has not been run end to end. Intel Macs, Linux and Windows are outside this repository’s tested path. The GUI packaging adjustment is compilation-checked separately. No populated data image, host state or private logs are distributed.

## One-command installer checks

- Piped-shell installation flow tested with mocked external commands, including default startup and `--no-start`.
- Existing workspace preservation, failed-guest recovery and read-only preflight covered by automated tests (`python3 -m unittest discover -s tests -v`).
- Actual microsandbox 0.7.13 creation of an isolated Ubuntu builder, formatting and filesystem checks of two 1 GiB test volumes, graceful shutdown and removal passed. Production capacities are 256 GiB and 8 GiB.
- Native Finder bookmark shortcuts were created successfully in a temporary directory.
- The full fresh installation, including the first native Docker build, has not been rerun end to end through the published one-liner.

## Separate-installation startup regression

Fresh installs now receive a persistent `runtime-id`, used by the launcher for sandbox lookup, start and stop. Existing workspaces without this file retain the legacy `nomad-x5` identity. This prevents a fresh second install from trying to discard or rebind the first installation’s VM when no recovery archive exists yet. The dashboard port is still shared, so only one installation should run at a time.
