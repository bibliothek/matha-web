#!/usr/bin/env bash
# Pulls the image tags pinned in images.yml and recreates the services whose
# image changed; the rest keep running. Safe to run from cron.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== $(date '+%Y-%m-%dT%H:%M:%S%z')"

docker compose pull -q --ignore-pull-failures
docker compose up -d
docker image prune -f
