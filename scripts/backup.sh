#!/usr/bin/env bash
# Archives the app state directory and prunes archives older than 60 days.
# Safe to run from cron.
#
#   ./scripts/backup.sh
#
# DATA_ROOT   what to archive   (default /app, or the value in .env)
# BACKUP_DIR  where to write it (default /var/backups/matha-web)
# KEEP_DAYS   retention         (default 60)
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$repo_dir/.env" ]]; then
  set -a; . "$repo_dir/.env"; set +a
fi

src="${DATA_ROOT:-/app}"
dest="${BACKUP_DIR:-/var/backups/matha-web}"
keep_days="${KEEP_DAYS:-60}"

echo "=== $(date '+%Y-%m-%dT%H:%M:%S%z')"

[[ -d "$src" ]] || { echo "nothing to archive: $src does not exist" >&2; exit 1; }
case "$dest/" in
  "$src"/*) echo "BACKUP_DIR must not live inside $src" >&2; exit 1 ;;
esac

mkdir -p "$dest"
chmod 700 "$dest"

archive="$dest/$(basename "$src")-$(date '+%Y-%m-%d').tar.gz"
tar czf "$archive.part" -C "$(dirname "$src")" "$(basename "$src")"
mv "$archive.part" "$archive"
chmod 600 "$archive"
echo "wrote $archive ($(du -h "$archive" | cut -f1))"

pruned=$(find "$dest" -maxdepth 1 -type f -name "$(basename "$src")-*.tar.gz" \
  -mtime "+$keep_days" -print -delete | wc -l | tr -d ' ')
echo "kept $keep_days days, pruned $pruned"
