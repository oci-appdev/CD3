#!/usr/bin/env bash
# Download, verify, and extract a logical CD3 backup into a new staging directory.
# This script never overwrites the original CD3 installation.
set -Eeuo pipefail
umask 077

SCRIPT_VERSION="1.0.1"
CONFIG_FILE="/etc/cd3-backup/cd3-backup.conf"
BACKUP_ID=""
TARGET_DIR=""
EXECUTE=false

usage() {
  cat <<'USAGE'
Usage: restore_cd3_artifacts.sh --target-dir ABSOLUTE_PATH [options]

Options:
  --config FILE       Configuration file
  --backup-id ID      Specific backup ID; otherwise select the newest backup
  --target-dir PATH   New or empty staging directory
  --execute           Perform download and extraction; otherwise show the plan
  --help              Show this help

This restores logical files only. Full VM recovery is performed from the OCI boot or volume-group backup.
USAGE
}

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
is_true() { case "${1,,}" in true|yes|1) return 0 ;; *) return 1 ;; esac; }
sanitize_name() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//' | cut -c1-100; }

args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --config) ((i+1<${#args[@]})) || die "--config requires a file."; CONFIG_FILE="${args[$((i+1))]}"; ((i+=1)) ;;
    --backup-id) ((i+1<${#args[@]})) || die "--backup-id requires a value."; BACKUP_ID="${args[$((i+1))]}"; ((i+=1)) ;;
    --target-dir) ((i+1<${#args[@]})) || die "--target-dir requires a path."; TARGET_DIR="${args[$((i+1))]}"; ((i+=1)) ;;
    --execute) EXECUTE=true ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: ${args[$i]}" ;;
  esac
done

[[ -r "$CONFIG_FILE" ]] || die "Configuration file is not readable: $CONFIG_FILE"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
for cmd in oci jq curl sha256sum tar sort tail; do command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"; done

[[ "$TARGET_DIR" == /* ]] || die "--target-dir must be an absolute path."
case "$TARGET_DIR" in
  /|/etc|/var|/home|/root|/usr|/opt) die "Choose a dedicated restore staging directory, not a broad system directory." ;;
esac

BACKUP_BUCKET="${BACKUP_BUCKET:-}"
OBJECT_PREFIX="${OBJECT_PREFIX:-cd3}"
OCI_REGION="${OCI_REGION:-}"
OCI_AUTH_MODE="${OCI_AUTH_MODE:-instance_principal}"
USE_REALM_SPECIFIC_ENDPOINT="${USE_REALM_SPECIFIC_ENDPOINT:-true}"
INSTANCE_BACKUP_NAME="${INSTANCE_BACKUP_NAME:-}"

metadata='{}'
if [[ -z "$OCI_REGION" || -z "$INSTANCE_BACKUP_NAME" ]]; then
  metadata="$(curl -fsS --connect-timeout 3 --max-time 10 -H 'Authorization: Bearer Oracle' 'http://169.254.169.254/opc/v2/instance/' 2>/dev/null || printf '{}')"
fi
OCI_REGION="${OCI_REGION:-$(jq -r '.canonicalRegionName // .region // empty' <<<"$metadata")}"
INSTANCE_BACKUP_NAME="${INSTANCE_BACKUP_NAME:-$(jq -r '.displayName // empty' <<<"$metadata")}"
INSTANCE_BACKUP_NAME="$(sanitize_name "$INSTANCE_BACKUP_NAME")"
[[ -n "$BACKUP_BUCKET" && -n "$OCI_REGION" && -n "$INSTANCE_BACKUP_NAME" ]] || die "BACKUP_BUCKET, OCI_REGION, and INSTANCE_BACKUP_NAME are required."

oci_cmd() {
  local command=(oci "$@")
  [[ -z "$OCI_AUTH_MODE" ]] || command+=(--auth "$OCI_AUTH_MODE")
  command+=(--region "$OCI_REGION")
  is_true "$USE_REALM_SPECIFIC_ENDPOINT" && command+=(--realm-specific-endpoint)
  "${command[@]}"
}

temp_dir="$(mktemp -d)"
trap 'rm -rf -- "$temp_dir"' EXIT
root_prefix="$OBJECT_PREFIX/$INSTANCE_BACKUP_NAME/"
oci_cmd os object list --bucket-name "$BACKUP_BUCKET" --prefix "$root_prefix" --all >"$temp_dir/objects.json"
jq -e 'type == "object"' >/dev/null <"$temp_dir/objects.json" || die "Object Storage listing could not be parsed."
filter='select(.name | endswith("/cd3-backup.tar.gz"))'
if [[ -n "$BACKUP_ID" ]]; then
  filter="$filter | select(.name | contains(\"/$BACKUP_ID/\"))"
fi
archive_object="$(jq -r ".data.objects[]? | $filter | [(.\"time-created\" // \"\"), .name] | @tsv" "$temp_dir/objects.json" | sort | tail -1 | cut -f2-)"
if [[ -z "$archive_object" ]]; then
  if [[ -n "$BACKUP_ID" ]]; then
    if jq -e --arg id "$BACKUP_ID" '.data.objects[]? | select(.name | contains("/" + $id + "/"))' "$temp_dir/objects.json" >/dev/null; then
      die "Backup $BACKUP_ID exists but contains no logical archive (volume-only backup). Recover it from the OCI volume or volume-group backup instead."
    fi
  elif jq -e '.data.objects[]? | select(.name | endswith("/backup-manifest.json"))' "$temp_dir/objects.json" >/dev/null; then
    die "Backups exist for this instance but none contain a logical archive (they are volume-only). Recover from the OCI volume or volume-group backup instead."
  fi
  die "No matching logical CD3 backup was found."
fi
object_dir="${archive_object%/*}"

printf 'Selected backup: %s\n' "$archive_object"
printf 'Restore target: %s\n' "$TARGET_DIR"
if ! is_true "$EXECUTE"; then
  printf 'DRY RUN ONLY. Re-run with --execute to download, verify, and extract.\n'
  exit 0
fi

if [[ -e "$TARGET_DIR" ]]; then
  [[ -d "$TARGET_DIR" ]] || die "Restore target exists and is not a directory."
  [[ -z "$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die "Restore target must be empty."
else
  mkdir -p "$TARGET_DIR"
fi
chmod 700 "$TARGET_DIR"

oci_cmd os object get --bucket-name "$BACKUP_BUCKET" --name "$archive_object" --file "$temp_dir/cd3-backup.tar.gz"
oci_cmd os object get --bucket-name "$BACKUP_BUCKET" --name "$object_dir/SHA256SUMS" --file "$temp_dir/SHA256SUMS"
(cd "$temp_dir" && sha256sum -c SHA256SUMS)

tar -tzf "$temp_dir/cd3-backup.tar.gz" >"$temp_dir/archive-listing.txt" || die "The archive could not be read."
unsafe_entry="$(grep -E '(^/|(^|/)\.\.(/|$))' "$temp_dir/archive-listing.txt" | head -1 || true)"
[[ -z "$unsafe_entry" ]] || die "Unsafe path detected in archive: $unsafe_entry"

# A member path can be safe while its LINK TARGET escapes the staging directory:
# a symlink to / followed by a file written through it is the classic tar escape.
tar -tvzf "$temp_dir/cd3-backup.tar.gz" >"$temp_dir/archive-listing-verbose.txt" || die "The archive could not be read."
unsafe_link="$(awk -F' -> ' '/ -> /{print $2}' "$temp_dir/archive-listing-verbose.txt" | grep -E '(^/|(^|/)\.\.(/|$))' | head -1 || true)"
[[ -z "$unsafe_link" ]] || die "Unsafe link target detected in archive: $unsafe_link"

tar -xzf "$temp_dir/cd3-backup.tar.gz" -C "$TARGET_DIR" --no-same-owner

printf 'Logical CD3 restore completed in: %s\n' "$TARGET_DIR"
printf 'Review the files before copying anything into the active CD3 installation.\n'

