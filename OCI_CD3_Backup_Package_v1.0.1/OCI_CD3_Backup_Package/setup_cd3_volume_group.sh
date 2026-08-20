#!/usr/bin/env bash
# Discover the target instance volumes and optionally create a coordinated OCI volume group.
set -Eeuo pipefail
umask 077

SCRIPT_VERSION="1.0.1"
CONFIG_FILE="/etc/cd3-backup/cd3-backup.conf"
EXECUTE=false

usage() {
  cat <<'USAGE'
Usage: setup_cd3_volume_group.sh [--config FILE] [--execute]

Without --execute, the script performs discovery and prints the proposed volume group.
With --execute, it creates the OCI volume group and prints its OCID. It does not edit the configuration file.
USAGE
}

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
is_true() { case "${1,,}" in true|yes|1) return 0 ;; *) return 1 ;; esac; }
sanitize_name() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//' | cut -c1-70; }

# Read command output into an array, failing the script if the command fails.
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
    --execute) EXECUTE=true ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: ${args[$i]}" ;;
  esac
done

[[ -r "$CONFIG_FILE" ]] || die "Configuration file is not readable: $CONFIG_FILE"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

for cmd in oci jq curl sha256sum; do command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"; done

OCI_REGION="${OCI_REGION:-}"
OCI_AUTH_MODE="${OCI_AUTH_MODE:-instance_principal}"
USE_REALM_SPECIFIC_ENDPOINT="${USE_REALM_SPECIFIC_ENDPOINT:-true}"
INSTANCE_OCID="${INSTANCE_OCID:-}"
INSTANCE_COMPARTMENT_OCID="${INSTANCE_COMPARTMENT_OCID:-}"
AVAILABILITY_DOMAIN="${AVAILABILITY_DOMAIN:-}"
INSTANCE_BACKUP_NAME="${INSTANCE_BACKUP_NAME:-}"
if [[ -z "${FREEFORM_TAGS_JSON:-}" ]]; then
  FREEFORM_TAGS_JSON='{"ManagedBy":"CD3Backup","Compliance":"SCCA"}'
fi
DEFINED_TAGS_JSON="${DEFINED_TAGS_JSON:-}"
VOLUME_BACKUP_POLICY_OCID="${VOLUME_BACKUP_POLICY_OCID:-}"

metadata='{}'
if [[ -z "$INSTANCE_OCID" || -z "$INSTANCE_COMPARTMENT_OCID" || -z "$OCI_REGION" || -z "$AVAILABILITY_DOMAIN" || -z "$INSTANCE_BACKUP_NAME" ]]; then
  metadata="$(curl -fsS --connect-timeout 3 --max-time 10 -H 'Authorization: Bearer Oracle' 'http://169.254.169.254/opc/v2/instance/' 2>/dev/null || printf '{}')"
fi
INSTANCE_OCID="${INSTANCE_OCID:-$(jq -r '.id // empty' <<<"$metadata")}"
INSTANCE_COMPARTMENT_OCID="${INSTANCE_COMPARTMENT_OCID:-$(jq -r '.compartmentId // empty' <<<"$metadata")}"
OCI_REGION="${OCI_REGION:-$(jq -r '.canonicalRegionName // .region // empty' <<<"$metadata")}"
AVAILABILITY_DOMAIN="${AVAILABILITY_DOMAIN:-$(jq -r '.availabilityDomain // empty' <<<"$metadata")}"
INSTANCE_BACKUP_NAME="${INSTANCE_BACKUP_NAME:-$(jq -r '.displayName // "cd3-instance"' <<<"$metadata")}"
INSTANCE_BACKUP_NAME="$(sanitize_name "$INSTANCE_BACKUP_NAME")"

[[ -n "$INSTANCE_OCID" && -n "$INSTANCE_COMPARTMENT_OCID" && -n "$OCI_REGION" && -n "$AVAILABILITY_DOMAIN" ]] || die "Instance identity could not be discovered."

oci_cmd() {
  local command=(oci "$@")
  [[ -z "$OCI_AUTH_MODE" ]] || command+=(--auth "$OCI_AUTH_MODE")
  command+=(--region "$OCI_REGION")
  is_true "$USE_REALM_SPECIFIC_ENDPOINT" && command+=(--realm-specific-endpoint)
  "${command[@]}"
}

oci_cmd os ns get >/dev/null
boot_json="$(oci_cmd compute boot-volume-attachment list --availability-domain "$AVAILABILITY_DOMAIN" --compartment-id "$INSTANCE_COMPARTMENT_OCID" --instance-id "$INSTANCE_OCID" --all)"
block_json="$(oci_cmd compute volume-attachment list --compartment-id "$INSTANCE_COMPARTMENT_OCID" --instance-id "$INSTANCE_OCID" --all)"
boot_id="$(jq -r '[.data[]? | select((."lifecycle-state" // "") == "ATTACHED") | ."boot-volume-id"] | map(select(. != null)) | first // empty' <<<"$boot_json")"
[[ -n "$boot_id" ]] || die "No attached boot volume was found."
block_json_file="$(mktemp)"; printf '%s' "$block_json" >"$block_json_file"
read_lines_or_die block_ids "the block-volume attachment list" \
  jq -r '.data[]? | select((."lifecycle-state" // "") == "ATTACHED") | ."volume-id" // empty' "$block_json_file"
rm -f -- "$block_json_file"
volume_ids=("$boot_id" ${block_ids[@]+"${block_ids[@]}"})
volume_ids_json="$(jq -n '$ARGS.positional' --args "${volume_ids[@]}")"
source_details="$(jq -cn --argjson ids "$volume_ids_json" '{type:"volumeIds",volumeIds:$ids}')"
display_name="cd3-$INSTANCE_BACKUP_NAME-backup-group"

printf 'Instance OCID: %s\n' "$INSTANCE_OCID"
printf 'Availability domain: %s\n' "$AVAILABILITY_DOMAIN"
printf 'Volumes discovered: %s\n' "${#volume_ids[@]}"
printf 'Source details: %s\n' "$source_details"

if ! is_true "$EXECUTE"; then
  printf '\nDRY RUN ONLY. Re-run with --execute to create the volume group.\n'
  exit 0
fi

freeform_tags="$(jq -cn --argjson base "$FREEFORM_TAGS_JSON" --arg instance "$INSTANCE_OCID" '$base + {ProtectedInstance:$instance}')"
create_args=(
  --availability-domain "$AVAILABILITY_DOMAIN"
  --compartment-id "$INSTANCE_COMPARTMENT_OCID"
  --source-details "$source_details"
  --display-name "$display_name"
  --freeform-tags "$freeform_tags"
  --wait-for-state AVAILABLE
  --max-wait-seconds 3600
)
[[ -z "$DEFINED_TAGS_JSON" ]] || create_args+=(--defined-tags "$DEFINED_TAGS_JSON")
[[ -z "$VOLUME_BACKUP_POLICY_OCID" ]] || create_args+=(--backup-policy-id "$VOLUME_BACKUP_POLICY_OCID")

response="$(oci_cmd bv volume-group create "${create_args[@]}")"
volume_group_id="$(jq -r '.data.id // empty' <<<"$response")"
[[ -n "$volume_group_id" ]] || die "OCI did not return a volume-group OCID."
printf '\nVolume group created successfully.\n'
printf 'VOLUME_GROUP_OCID="%s"\n' "$volume_group_id"
printf 'Copy that line into: %s\n' "$CONFIG_FILE"
