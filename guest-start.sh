#!/usr/bin/env bash
set -euo pipefail
for target in /opt/project-nomad /var/lib/docker; do
  if ! mountpoint -q "$target"; then
    echo "Required external disk is not mounted at $target. Stop and restart the sandbox." >&2
    exit 1
  fi
done
# Raw disk files can be enlarged while stopped. Grow the ext4 filesystem to the
# attached block device before starting databases or Docker; never shrink it.
for target in /opt/project-nomad /var/lib/docker; do
  device=$(findmnt -n -o SOURCE --target "$target")
  case "$device" in /dev/vd*) resize2fs "$device" ;; *) echo "Unexpected external device: $device" >&2; exit 1 ;; esac
done
mkdir -p /opt/project-nomad/storage/logs /etc/docker
# NOMAD's disk collector uses an rslave bind mount of the guest root.
mount --make-rshared /
# Keep the image store on the external Docker disk, including on Docker 29+.
printf '%s\n' '{"features":{"containerd-snapshotter":false},"storage-driver":"overlay2","exec-opts":["native.cgroupdriver=cgroupfs"]}' > /etc/docker/daemon.json
if [ ! -e /proc/sys/fs/binfmt_misc/register ]; then
  mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
fi
if [ "$(uname -m)" = aarch64 ] && [ -f /usr/lib/binfmt.d/qemu-x86_64.conf ]; then
  # Ubuntu 24.04 ships this registration in systemd's format, outside the
  # update-binfmts database. The one-shot importer works without systemd PID 1.
  if ! /usr/lib/systemd/systemd-binfmt /usr/lib/binfmt.d/qemu-x86_64.conf; then
    echo 'Optional AMD64 compatibility is unavailable; native apps can still start.' >&2
  fi
fi
if ! docker info >/dev/null 2>&1; then
  rm -f /var/run/docker.pid
  nohup dockerd > /opt/project-nomad/storage/logs/docker-daemon.log 2>&1 </dev/null &
  for i in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done
  docker info >/dev/null
fi
cd /usr/local/src/project-nomad
arch=$(dpkg --print-architecture)
revision=54ee30a
version=$(python3 -c 'import json; print(json.load(open("package.json"))["version"])')
for component in admin updater disk-collector; do
  tag="nomad-local/$component:$revision-$arch"
  if ! docker image inspect "$tag" >/dev/null 2>&1; then
    case "$component" in
      admin) docker build --build-arg "TARGETARCH=$arch" --build-arg "VERSION=$version" --build-arg "VCS_REF=$revision" -t "$tag" . ;;
      updater) docker build -t "$tag" install/sidecar-updater ;;
      disk-collector) docker build -t "$tag" install/sidecar-disk-collector ;;
    esac
  fi
done
if [ ! -f /opt/project-nomad/compose.yml ]; then
  python3 - <<'PY'
import pathlib, secrets
src = pathlib.Path('/usr/local/src/project-nomad/install/management_compose.yaml').read_text()
db_password = secrets.token_hex(24)
for old, new in {
    'URL=replaceme': 'URL=http://localhost:8080',
    'APP_KEY=replaceme': 'APP_KEY=' + secrets.token_hex(32),
    'DB_PASSWORD=replaceme': 'DB_PASSWORD=' + db_password,
    'MYSQL_PASSWORD=replaceme': 'MYSQL_PASSWORD=' + db_password,
    'MYSQL_ROOT_PASSWORD=replaceme': 'MYSQL_ROOT_PASSWORD=' + secrets.token_hex(32),
}.items():
    src = src.replace(old, new)
dst = pathlib.Path('/opt/project-nomad/compose.yml')
dst.write_text(src)
dst.chmod(0o600)
PY
fi
cat > /opt/project-nomad/compose.native.yml <<EOF
services:
  admin:
    image: nomad-local/admin:$revision-$arch
    pull_policy: never
  updater:
    image: nomad-local/updater:$revision-$arch
    pull_policy: never
    profiles: [manual-updates]
  disk-collector:
    image: nomad-local/disk-collector:$revision-$arch
    pull_policy: never
  mysql:
    image: mysql:8.0@sha256:7dcddc01f13bab2f15cde676d44d01f61fc9f99fe7785e86196dfc07d358ae2b
    healthcheck:
      interval: 3s
      start_period: 5s
  redis:
    healthcheck:
      interval: 3s
      start_period: 5s
EOF
docker compose -p project-nomad -f /opt/project-nomad/compose.yml -f /opt/project-nomad/compose.native.yml up -d
# Docker's unless-stopped policy preserves a manual stop. Resume exactly the
# managed apps that were running when this adapter last shut down.
if [ -f /opt/project-nomad/storage/.portable-running-apps ]; then
  while IFS= read -r app; do
    case "$app" in nomad_updater|nomad_ollama) continue ;; nomad_*) ;; *) continue ;; esac
    if docker container inspect "$app" >/dev/null 2>&1; then
      if [ "$(docker inspect --format '{{.State.Running}}' "$app")" != true ]; then docker start "$app"; fi
    fi
  done < /opt/project-nomad/storage/.portable-running-apps
fi
echo 'Project NOMAD services started.'
