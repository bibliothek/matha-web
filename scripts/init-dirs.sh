#!/usr/bin/env bash
# Creates the host directories the stack bind-mounts, with the ownership each
# container needs. MathaHub and the Checklist run as uid 1654 ($APP_UID in the
# .NET images) and bind mounts do not inherit the image's ownership.
#
#   sudo ./scripts/init-dirs.sh
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$repo_dir/.env" ]]; then
  set -a; . "$repo_dir/.env"; set +a
fi
data_root="${DATA_ROOT:-/app}"
app_uid=1654

mkdir -p "$data_root"/mathauth/{data/keys,config,certs} \
         "$data_root"/mathahub/links \
         "$data_root"/extensible-checklist/data

chown -R "$app_uid:$app_uid" "$data_root/mathahub/links" \
                             "$data_root/extensible-checklist/data"
chmod 0750 "$data_root/mathauth/certs"

clients_file="$data_root/mathauth/config/oidc-clients.json"
if [[ -e "$clients_file" ]]; then
  echo "kept:    $clients_file"
else
  printf '{\n  "OidcClients": []\n}\n' > "$clients_file"
  chmod 0640 "$clients_file"
  echo "created: $clients_file (empty — add your client registrations)"
fi

echo
echo "Ready under $data_root. Still needed:"
echo "  $data_root/mathauth/certs/{signing,encryption}.pfx"
echo "  $data_root/mathahub/links/<username>.json"
