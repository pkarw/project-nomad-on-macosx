#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  apt-get update
  apt-get install -y ca-certificates curl gnupg python3 git qemu-user-static binfmt-support
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  arch=$(dpkg --print-architecture)
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable\n' "$arch" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
mkdir -p /usr/local/src/project-nomad
if [ ! -f /usr/local/src/project-nomad/Dockerfile ]; then
  curl -fsSL https://api.github.com/repos/Crosstalk-Solutions/project-nomad/tarball/54ee30a44902e5c252b477f8685c26ec3064ab72 |
    tar -xz --strip-components=1 -C /usr/local/src/project-nomad
fi
echo 'Ubuntu dependencies ready.'
