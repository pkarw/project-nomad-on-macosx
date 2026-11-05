#!/usr/bin/env bash
set -euo pipefail

if docker info >/dev/null 2>&1; then
  docker ps --format '{{.Names}}' --filter name=nomad_ > /opt/project-nomad/storage/.portable-running-apps

  # Let application workers finish their writes while Redis and MySQL remain up.
  if [ -n "$(docker ps -q --filter 'name=^/nomad_admin$')" ]; then
    docker stop -t 30 nomad_admin
  fi
  if [ -n "$(docker ps -q --filter 'name=^/nomad_disk_collector$')" ]; then
    docker stop -t 3 nomad_disk_collector
  fi
  apps=()
  while IFS= read -r app; do
    case "$app" in nomad_mysql|nomad_redis) ;; nomad_*) apps+=("$app") ;; esac
  done < <(docker ps --format '{{.Names}}' --filter name=nomad_)
  if [ "${#apps[@]}" -gt 0 ]; then docker stop -t 30 "${apps[@]}"; fi
  for database in nomad_redis nomad_mysql; do
    if [ -n "$(docker ps -q --filter "name=^/$database\$")" ]; then docker stop -t 30 "$database"; fi
  done

  if [ -f /var/run/docker.pid ]; then
    pid=$(cat /var/run/docker.pid)
    kill -TERM "$pid"
    for i in $(seq 1 45); do
      if ! kill -0 "$pid" 2>/dev/null; then break; fi
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo 'Docker is still running; the disk is not safe to eject.' >&2
      exit 1
    fi
  fi
fi

sync
for target in /var/lib/docker /opt/project-nomad; do
  if mountpoint -q "$target"; then umount "$target"; fi
done
sync
