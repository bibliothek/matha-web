#!/usr/bin/env bash
# Fast-forwards the checkout to pick up tag bumps in images.yml, pulls those
# images and recreates the services whose image changed; the rest keep running.
# Safe to run from cron.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== $(date '+%Y-%m-%dT%H:%M:%S%z')"

git pull -q --ff-only
docker compose pull -q --ignore-pull-failures
docker compose up -d
docker image prune -f
