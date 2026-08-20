#!/usr/bin/env bash
# Verify a logical CD3 backup and every OCI volume backup record in its manifest.
#
# This script fails closed: any step that cannot be evaluated is an error, not a
# silent pass. It exits non-zero unless it positively confirmed every check it
# reports, and it always prints how many OCI backup records it examined.
set -Eeuo pipefail
umask 077

SCRIPT_VERSION="1.0.2"
CONFIG_FILE="/etc/cd3-backup/cd3-backup.conf"
BACKUP_ID=""
BACKUP_CLASS_FILTER=""

usage() {
  cat <<'USAGE'
Usage: verify_cd3_backup.sh [--config FILE] [--backup-id ID] [--backup-class CLASS]

If no backup ID is supplied, the newest backup is selected by Object Storage creation time.

Exit codes:
  0  every check passed
  1  a check failed, or the backup could not be evaluated
USAGE
}

LAST_ERROR=""
NOTIFY_READY=false
NOTIFICATION_SENT=false
die() { LAST_ERROR="$1"; printf 'ERROR: %s\n' "$1" >&2; exit 1; }
is_true() { case "${1,,}" in true|yes|1) return 0 ;; *) return 1 ;; esac; }
sanitize_name() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//' | cut -c1-100; }

# Read command output into an array, failing the script if the command fails.
# "mapfile < <(cmd)" cannot do this: the failure happens in a subshell, so
# set -e never sees it and the caller silently proceeds with zero rows.
read_lines_or_die() {
  local -n _target="$1"; shift
  local _label="$1"; shift
  local _tmp
  _tmp="$(mktemp)"
  if ! "$@" >"$_tmp" 2>/dev/null; then
    rm -f -- "$_tmp"
    die "Failed to evaluate $_label."
  fi
  _target=()
  local _line
  while IFS= read -r _line; do
    [[ -n "$_line" ]] && _target+=("$_line")
  done <"$_tmp"
  rm -f -- "$_tmp"
}

args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --config) ((i+1<${#args[@]})) || die "--config requires a file."; CONFIG_FILE="${args[$((i+1))]}"; ((i+=1)) ;;
    --backup-id) ((i+1<${#args[@]})) || die "--backup-id requires a value."; BACKUP_ID="${args[$((i+1))]}"; ((i+=1)) ;;
    --backup-class) ((i+1<${#args[@]})) || die "--backup-class requires a value."; BACKUP_CLASS_FILTER="${args[$((i+1))]}"; ((i+=1)) ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: ${args[$i]}" ;;
  esac
done

[[ -r "$CONFIG_FILE" ]] || die "Configuration file is not readable: $CONFIG_FILE"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
for cmd in oci jq curl sha256sum tar sort tail; do command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"; done

BACKUP_BUCKET="${BACKUP_BUCKET:-}"
OBJECT_PREFIX="${OBJECT_PREFIX:-cd3}"
OCI_REGION="${OCI_REGION:-}"
OCI_AUTH_MODE="${OCI_AUTH_MODE:-instance_principal}"
USE_REALM_SPECIFIC_ENDPOINT="${USE_REALM_SPECIFIC_ENDPOINT:-true}"
INSTANCE_BACKUP_NAME="${INSTANCE_BACKUP_NAME:-}"
ONS_TOPIC_OCID="${ONS_TOPIC_OCID:-}"
NOTIFY_ON_SUCCESS="${NOTIFY_ON_SUCCESS:-true}"
NOTIFY_ON_FAILURE="${NOTIFY_ON_FAILURE:-true}"
NOTIFY_SUBJECT_PREFIX="${NOTIFY_SUBJECT_PREFIX:-[CD3 Backup]}"
NOTIFY_ENVIRONMENT="${NOTIFY_ENVIRONMENT:-}"
NOTIFY_ON_VERIFY="${NOTIFY_ON_VERIFY:-true}"

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

# A backup that has silently gone bad is exactly the thing worth emailing about,
# so verification reports through the same topic as the backup itself.
send_verify_notification() {
  local rc="$1"
  is_true "$NOTIFICATION_SENT" && return 0
  NOTIFICATION_SENT=true
  is_true "$NOTIFY_ON_VERIFY" || return 0
  [[ -n "$ONS_TOPIC_OCID" ]] || return 0
  is_true "$NOTIFY_READY" || return 0
  local env_tag="" title body
  [[ -n "$NOTIFY_ENVIRONMENT" ]] && env_tag=" $NOTIFY_ENVIRONMENT"
  if (( rc == 0 )); then
    is_true "$NOTIFY_ON_SUCCESS" || return 0
    title="$NOTIFY_SUBJECT_PREFIX${env_tag} VERIFY OK - ${INSTANCE_BACKUP_NAME}"
    body="CD3 backup verification passed.

Instance:   ${INSTANCE_BACKUP_NAME}
Region:     ${OCI_REGION}
Backup:     ${manifest_backup_id:-unknown}
Mode:       ${manifest_mode:-unknown}
Location:   ${object_dir:-unknown}
Checks run: ${checks_passed:-0}
Time (UTC): $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  else
    is_true "$NOTIFY_ON_FAILURE" || return 0
    title="$NOTIFY_SUBJECT_PREFIX${env_tag} VERIFY FAILED - ${INSTANCE_BACKUP_NAME}"
    body="CD3 BACKUP VERIFICATION FAILED. Treat this backup as unusable.

Instance:   ${INSTANCE_BACKUP_NAME}
Region:     ${OCI_REGION}
Backup:     ${manifest_backup_id:-not determined}
Location:   ${object_dir:-not determined}
Exit code:  ${rc}
Reason:     ${LAST_ERROR:-verification returned a non-zero status}
Time (UTC): $(date -u +'%Y-%m-%dT%H:%M:%SZ')

Do not restore from this backup. Take a fresh one and verify it:
  /opt/cd3-backup/backup_cd3_instance.sh --config ${CONFIG_FILE} --mode full --backup-type FULL"
  fi
  if (( ${#body} > 60000 )); then body="${body:0:60000}"; fi
  oci_cmd ons message publish --topic-id "$ONS_TOPIC_OCID" --title "$title" --body "$body" >/dev/null 2>&1 \
    || printf 'WARNING: the verification result could not be published to the notification topic.\n' >&2
}

manifest_backup_id=""
manifest_mode=""
object_dir=""
checks_passed=0

temp_dir="$(mktemp -d)"
cleanup() {
  local rc=$?
  trap - EXIT
  send_verify_notification "$rc"
  rm -rf -- "$temp_dir"
  exit "$rc"
}
trap cleanup EXIT
root_prefix="$OBJECT_PREFIX/$INSTANCE_BACKUP_NAME/"
oci_cmd os object list --bucket-name "$BACKUP_BUCKET" --prefix "$root_prefix" --all >"$temp_dir/objects.json"
NOTIFY_READY=true
jq -e 'type == "object"' >/dev/null <"$temp_dir/objects.json" || die "Object Storage listing could not be parsed."

# Select on the manifest, not the archive: volume-only backups have a manifest
# but no archive, and selecting on the archive made them unverifiable.
selection_filter='select(.name | endswith("/backup-manifest.json"))'
if [[ -n "$BACKUP_ID" ]]; then
  selection_filter="$selection_filter | select(.name | contains(\"/$BACKUP_ID/\"))"
fi
if [[ -n "$BACKUP_CLASS_FILTER" ]]; then
  selection_filter="$selection_filter | select(.name | contains(\"/$BACKUP_CLASS_FILTER/\"))"
fi
manifest_object="$(jq -r ".data.objects[]? | $selection_filter | [(.\"time-created\" // \"\"), .name] | @tsv" "$temp_dir/objects.json" | sort | tail -1 | cut -f2-)"
[[ -n "$manifest_object" ]] || die "No matching CD3 backup manifest was found."
object_dir="${manifest_object%/*}"

printf 'Verifying backup at: %s\n' "$object_dir"
oci_cmd os object get --bucket-name "$BACKUP_BUCKET" --name "$manifest_object" --file "$temp_dir/backup-manifest.json"
jq -e 'type == "object" and has("backupId")' >/dev/null <"$temp_dir/backup-manifest.json" \
  || die "The backup manifest is missing or corrupt. This backup cannot be trusted."

manifest_backup_id="$(jq -r '.backupId // empty' "$temp_dir/backup-manifest.json")"
manifest_mode="$(jq -r '.mode // "full"' "$temp_dir/backup-manifest.json")"
[[ -n "$manifest_backup_id" ]] || die "The backup manifest does not contain a backup ID."

# ---- 1. Logical archive: SHA-256 and required contents ----
if [[ "$manifest_mode" != "volume-only" ]]; then
  oci_cmd os object get --bucket-name "$BACKUP_BUCKET" --name "$object_dir/cd3-backup.tar.gz" --file "$temp_dir/cd3-backup.tar.gz"
  oci_cmd os object get --bucket-name "$BACKUP_BUCKET" --name "$object_dir/SHA256SUMS" --file "$temp_dir/SHA256SUMS"
  (cd "$temp_dir" && sha256sum -c SHA256SUMS) || die "SHA-256 verification of the logical archive FAILED."
  checks_passed=$((checks_passed + 1))

  archive_listing="$temp_dir/archive-listing.txt"
  tar -tzf "$temp_dir/cd3-backup.tar.gz" >"$archive_listing" || die "The logical archive could not be read."
  grep -qx 'backup-metadata/backup-manifest.json' "$archive_listing" || die "Archive is missing its internal backup manifest."
  grep -qx 'backup-metadata/inventory/instance.json' "$archive_listing" || die "Archive is missing the instance inventory."
  checks_passed=$((checks_passed + 1))
  printf 'Logical archive: SHA-256 OK, required inventory present (%s entries).\n' "$(wc -l <"$archive_listing")"
else
  printf 'Logical archive: not applicable (volume-only backup).\n'
fi

# ---- 2. Every OCI volume backup record still AVAILABLE ----
read_lines_or_die backup_records "the volume backup records in the manifest" \
  jq -c '.storage.volumeBackups[]?' "$temp_dir/backup-manifest.json"

record_count=${#backup_records[@]}
if [[ "$manifest_mode" == "config-only" ]]; then
  (( record_count == 0 )) || printf 'Note: a config-only backup unexpectedly carries %s volume backup record(s).\n' "$record_count"
elif (( record_count == 0 )); then
  die "Manifest mode is '$manifest_mode' but it contains no OCI volume backup records. Nothing to verify — treat this backup as unusable."
fi

for record in ${backup_records[@]+"${backup_records[@]}"}; do
  backup_type="$(jq -r '.type // empty' <<<"$record")"
  backup_ocid="$(jq -r '.id // empty' <<<"$record")"
  [[ -n "$backup_type" && -n "$backup_ocid" ]] || die "Malformed volume backup record in manifest: $record"
  case "$backup_type" in
    volume-group-backup) response="$(oci_cmd bv volume-group-backup get --volume-group-backup-id "$backup_ocid")" ;;
    boot-volume-backup) response="$(oci_cmd bv boot-volume-backup get --boot-volume-backup-id "$backup_ocid")" ;;
    volume-backup) response="$(oci_cmd bv backup get --volume-backup-id "$backup_ocid")" ;;
    *) die "Unknown backup type in manifest: $backup_type" ;;
  esac
  state="$(jq -r '.data."lifecycle-state" // empty' <<<"$response")"
  [[ "$state" == "AVAILABLE" ]] || die "$backup_ocid is not AVAILABLE; current state: ${state:-unknown}"
  expires="$(jq -r '.data."expiration-time" // .data."time-retention-expires-at" // "none"' <<<"$response")"
  printf 'OCI %s AVAILABLE: %s (expires: %s)\n' "$backup_type" "$backup_ocid" "$expires"
  checks_passed=$((checks_passed + 1))
done

if [[ "$manifest_mode" != "config-only" ]]; then
  printf 'OCI backup records checked: %s\n' "$record_count"
  if (( record_count == 0 )); then
    die "Internal check failed: no OCI backup records were examined."
  fi
fi

if (( checks_passed == 1 )); then
  printf 'Backup verification PASSED (1 check).\n'
else
  printf 'Backup verification PASSED (%s checks).\n' "$checks_passed"
fi
printf 'Backup ID: %s\n' "$manifest_backup_id"
printf 'Mode: %s\n' "$manifest_mode"
