#!/usr/bin/env bash
#
# Back up an OCI CD3 instance using OCI instance-principal authentication.
# Creates an OCI boot/volume-group backup and a logical CD3 backup in Object Storage.
#
set -Eeuo pipefail
umask 077

SCRIPT_VERSION="1.0.2"
DEFAULT_CONFIG="/etc/cd3-backup/cd3-backup.conf"
CONFIG_FILE="$DEFAULT_CONFIG"
MODE_OVERRIDE=""
TYPE_OVERRIDE=""
RETENTION_OVERRIDE=""
CLASS_OVERRIDE=""
PRE_CHANGE_LABEL=""
DRY_RUN=false
TEST_NOTIFICATION=false

# Notification state. These are set as early as possible so that the EXIT trap
# can always say something useful, even about a very early failure.
LAST_ERROR=""
RUN_STAGE="starting up"
NOTIFY_READY=false
NOTIFICATION_SENT=false
BACKUP_ID=""
START_EPOCH="$(date -u +%s)"
START_TIME="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
HOST_NAME="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown-host')"

usage() {
  sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'USAGE'

Usage:
  backup_cd3_instance.sh [options]

Options:
  --config FILE             Configuration file (default: /etc/cd3-backup/cd3-backup.conf)
  --mode MODE               full, config-only, or volume-only
  --backup-type TYPE        FULL or INCREMENTAL
  --retention-days DAYS     OCI volume-backup retention period
  --backup-class NAME       scheduled, pre-change, monthly, or another safe label
  --pre-change LABEL        Mark a pre-change backup and record the change label
  --dry-run                 Perform discovery and safety checks only
  --test-notification       Send a test notification and exit, without backing up
  --help                    Show this help

Notifications:
  Set ONS_TOPIC_OCID in the configuration to receive email on every run.
  Every failure path notifies, including safety-guard refusals. A dry run does
  not notify; use --test-notification to prove email delivery works.
USAGE
}

log() {
  printf '%s [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" >&2
}

die() {
  LAST_ERROR="$1"
  log ERROR "$1"
  exit 1
}

# Human-readable marker of what the script was doing, quoted in failure email.
stage() {
  RUN_STAGE="$1"
  log INFO "$1"
}

is_true() {
  case "${1,,}" in
    true|yes|1) return 0 ;;
    *) return 1 ;;
  esac
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

sanitize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//' | cut -c1-100
}

validate_positive_integer() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive integer."
}

# Read command output into an array. Unlike "mapfile < <(...)", this fails the
# script when the producing command fails instead of silently yielding no rows.
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

# Oracle documents the retentionPeriod complex type as retentionTimeAmount /
# retentionTimeUnit. RETENTION_PERIOD_JSON overrides this verbatim if a given
# OCI CLI build expects a different shape; confirm with
#   oci bv volume-group-backup create --generate-param-json-input retention-period
build_retention_json() {
  if [[ -n "$RETENTION_PERIOD_JSON" ]]; then
    printf '%s' "$RETENTION_PERIOD_JSON"
    return 0
  fi
  jq -cn --argjson days "$RETENTION_DAYS" '{retentionTimeAmount:$days,retentionTimeUnit:"DAYS"}'
}

validate_safe_class() {
  [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Backup class may contain only letters, numbers, dots, underscores, and hyphens."
}

# Locate --config and --help before loading the configuration.
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --config)
      (( i + 1 < ${#args[@]} )) || die "--config requires a file path."
      CONFIG_FILE="${args[$((i+1))]}"
      ((i+=1))
      ;;
    --help|-h)
      usage
      exit 0
      ;;
  esac
done

[[ -r "$CONFIG_FILE" ]] || die "Configuration file is not readable: $CONFIG_FILE"
config_mode="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || printf '600')"
if (( (8#$config_mode & 8#022) != 0 )); then
  die "Configuration file must not be group- or world-writable: $CONFIG_FILE"
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Configuration arrays are optional.
declare -a CD3_PATHS
declare -a EXCLUDE_PATTERNS
declare -a ORM_STACK_OCIDS

# Apply command-line overrides after loading the configuration.
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --config)
      ((i+=1))
      ;;
    --mode)
      (( i + 1 < ${#args[@]} )) || die "--mode requires a value."
      MODE_OVERRIDE="${args[$((i+1))]}"
      ((i+=1))
      ;;
    --backup-type)
      (( i + 1 < ${#args[@]} )) || die "--backup-type requires a value."
      TYPE_OVERRIDE="${args[$((i+1))]}"
      ((i+=1))
      ;;
    --retention-days)
      (( i + 1 < ${#args[@]} )) || die "--retention-days requires a value."
      RETENTION_OVERRIDE="${args[$((i+1))]}"
      ((i+=1))
      ;;
    --backup-class)
      (( i + 1 < ${#args[@]} )) || die "--backup-class requires a value."
      CLASS_OVERRIDE="${args[$((i+1))]}"
      ((i+=1))
      ;;
    --pre-change)
      (( i + 1 < ${#args[@]} )) || die "--pre-change requires a change label."
      PRE_CHANGE_LABEL="${args[$((i+1))]}"
      ((i+=1))
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --test-notification)
      TEST_NOTIFICATION=true
      ;;
    --help|-h)
      ;;
    *)
      die "Unknown option: ${args[$i]}"
      ;;
  esac
done

MODE="${MODE_OVERRIDE:-${BACKUP_MODE:-full}}"
BACKUP_TYPE="${TYPE_OVERRIDE:-${BACKUP_TYPE:-INCREMENTAL}}"
RETENTION_DAYS="${RETENTION_OVERRIDE:-${RETENTION_DAYS:-30}}"
BACKUP_CLASS="${CLASS_OVERRIDE:-${BACKUP_CLASS:-scheduled}}"
if [[ -n "$PRE_CHANGE_LABEL" && -z "$CLASS_OVERRIDE" ]]; then
  BACKUP_CLASS="pre-change"
fi

case "$MODE" in
  full|config-only|volume-only) ;;
  *) die "Invalid mode: $MODE" ;;
esac
BACKUP_TYPE="${BACKUP_TYPE^^}"
case "$BACKUP_TYPE" in
  FULL|INCREMENTAL) ;;
  *) die "BACKUP_TYPE must be FULL or INCREMENTAL." ;;
esac
validate_positive_integer RETENTION_DAYS "$RETENTION_DAYS"
validate_safe_class "$BACKUP_CLASS"

BACKUP_BUCKET="${BACKUP_BUCKET:-}"
OBJECT_PREFIX="${OBJECT_PREFIX:-cd3}"
OCI_REGION="${OCI_REGION:-}"
OCI_AUTH_MODE="${OCI_AUTH_MODE:-instance_principal}"
USE_REALM_SPECIFIC_ENDPOINT="${USE_REALM_SPECIFIC_ENDPOINT:-true}"
INSTANCE_OCID="${INSTANCE_OCID:-}"
INSTANCE_COMPARTMENT_OCID="${INSTANCE_COMPARTMENT_OCID:-}"
AVAILABILITY_DOMAIN="${AVAILABILITY_DOMAIN:-}"
INSTANCE_BACKUP_NAME="${INSTANCE_BACKUP_NAME:-}"
VOLUME_GROUP_OCID="${VOLUME_GROUP_OCID:-}"
ALLOW_INDIVIDUAL_VOLUME_BACKUPS="${ALLOW_INDIVIDUAL_VOLUME_BACKUPS:-false}"
REQUIRE_AT_LEAST_ONE_CD3_PATH="${REQUIRE_AT_LEAST_ONE_CD3_PATH:-true}"
WORK_ROOT="${WORK_ROOT:-/var/lib/cd3-backup}"
LOCK_FILE="${LOCK_FILE:-$WORK_ROOT/cd3-backup.lock}"
KEEP_LOCAL_COPY="${KEEP_LOCAL_COPY:-false}"
BACKUP_WAIT_SECONDS="${BACKUP_WAIT_SECONDS:-21600}"
ACTIVE_PROCESS_PATTERN="${ACTIVE_PROCESS_PATTERN:-terraform.*(apply|destroy|import)|cd3.*(apply|destroy)}"
if [[ -z "${FREEFORM_TAGS_JSON:-}" ]]; then
  FREEFORM_TAGS_JSON='{"ManagedBy":"CD3Backup","Compliance":"SCCA"}'
fi
DEFINED_TAGS_JSON="${DEFINED_TAGS_JSON:-}"
ONS_TOPIC_OCID="${ONS_TOPIC_OCID:-}"
NOTIFY_ON_SUCCESS="${NOTIFY_ON_SUCCESS:-true}"
NOTIFY_ON_FAILURE="${NOTIFY_ON_FAILURE:-true}"
NOTIFY_SUBJECT_PREFIX="${NOTIFY_SUBJECT_PREFIX:-[CD3 Backup]}"
NOTIFY_ENVIRONMENT="${NOTIFY_ENVIRONMENT:-}"
REQUIRE_NOTIFICATION_TOPIC="${REQUIRE_NOTIFICATION_TOPIC:-false}"
NOTIFY_ON_DRY_RUN="${NOTIFY_ON_DRY_RUN:-false}"
RETENTION_PERIOD_JSON="${RETENTION_PERIOD_JSON:-}"
APPLY_RETENTION_PERIOD="${APPLY_RETENTION_PERIOD:-true}"

validate_positive_integer BACKUP_WAIT_SECONDS "$BACKUP_WAIT_SECONDS"
[[ "$OBJECT_PREFIX" != /* ]] || die "OBJECT_PREFIX must not start with a slash."
[[ "$WORK_ROOT" == /* && "$WORK_ROOT" != "/" ]] || die "WORK_ROOT must be a specific absolute path."
[[ "$LOCK_FILE" == "$WORK_ROOT"/* ]] || die "LOCK_FILE must be beneath WORK_ROOT."
jq -e 'type == "object"' >/dev/null <<<"$FREEFORM_TAGS_JSON" || die "FREEFORM_TAGS_JSON must be a JSON object."
if [[ -n "$DEFINED_TAGS_JSON" ]]; then
  jq -e 'type == "object"' >/dev/null <<<"$DEFINED_TAGS_JSON" || die "DEFINED_TAGS_JSON must be a JSON object."
fi
if [[ -n "$RETENTION_PERIOD_JSON" ]]; then
  jq -e 'type == "object"' >/dev/null <<<"$RETENTION_PERIOD_JSON" || die "RETENTION_PERIOD_JSON must be a JSON object."
fi

require_command oci
require_command jq
require_command curl
require_command tar
require_command gzip
require_command sha256sum
require_command flock
require_command find
require_command ps

mkdir -p "$WORK_ROOT"
chmod 700 "$WORK_ROOT"
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another CD3 backup is already running."

METADATA_JSON='{}'
if [[ -z "$INSTANCE_OCID" || -z "$INSTANCE_COMPARTMENT_OCID" || -z "$OCI_REGION" || -z "$AVAILABILITY_DOMAIN" || -z "$INSTANCE_BACKUP_NAME" ]]; then
  METADATA_JSON="$(curl -fsS --connect-timeout 3 --max-time 10 \
    -H 'Authorization: Bearer Oracle' \
    'http://169.254.169.254/opc/v2/instance/' 2>/dev/null || printf '{}')"
fi

INSTANCE_OCID="${INSTANCE_OCID:-$(jq -r '.id // empty' <<<"$METADATA_JSON")}"
INSTANCE_COMPARTMENT_OCID="${INSTANCE_COMPARTMENT_OCID:-$(jq -r '.compartmentId // empty' <<<"$METADATA_JSON")}"
OCI_REGION="${OCI_REGION:-$(jq -r '.canonicalRegionName // .region // empty' <<<"$METADATA_JSON")}"
AVAILABILITY_DOMAIN="${AVAILABILITY_DOMAIN:-$(jq -r '.availabilityDomain // empty' <<<"$METADATA_JSON")}"
INSTANCE_DISPLAY_NAME="$(jq -r '.displayName // empty' <<<"$METADATA_JSON")"
INSTANCE_BACKUP_NAME="${INSTANCE_BACKUP_NAME:-$INSTANCE_DISPLAY_NAME}"
INSTANCE_BACKUP_NAME="$(sanitize_name "${INSTANCE_BACKUP_NAME:-cd3-instance}")"

[[ -n "$INSTANCE_OCID" ]] || die "INSTANCE_OCID could not be discovered. Run this script on the target OCI instance or set it in the configuration."
[[ -n "$INSTANCE_COMPARTMENT_OCID" ]] || die "INSTANCE_COMPARTMENT_OCID could not be discovered."
[[ -n "$OCI_REGION" ]] || die "OCI_REGION could not be discovered."
[[ -n "$AVAILABILITY_DOMAIN" ]] || die "AVAILABILITY_DOMAIN could not be discovered."
[[ -n "$INSTANCE_BACKUP_NAME" ]] || die "INSTANCE_BACKUP_NAME could not be determined."
if [[ "$MODE" != "volume-only" ]]; then
  [[ -n "$BACKUP_BUCKET" ]] || die "BACKUP_BUCKET is required for full and config-only backups."
fi

oci_cmd() {
  local command=(oci "$@")
  if [[ -n "$OCI_AUTH_MODE" ]]; then
    command+=(--auth "$OCI_AUTH_MODE")
  fi
  command+=(--region "$OCI_REGION")
  if is_true "$USE_REALM_SPECIFIC_ENDPOINT"; then
    command+=(--realm-specific-endpoint)
  fi
  "${command[@]}"
}

# Publish one message to the OCI Notifications topic. A publish failure is
# logged loudly rather than swallowed: silent alerting is worse than none,
# because it looks like everything is fine.
publish_message() {
  local title="$1"
  local body="$2"
  [[ -n "$ONS_TOPIC_OCID" ]] || return 0
  # ONS accepts up to 64 KB per message; keep well clear of the limit.
  if (( ${#body} > 60000 )); then
    body="${body:0:60000}"$'\n\n[message truncated]'
  fi
  local publish_output
  if publish_output="$(oci_cmd ons message publish \
        --topic-id "$ONS_TOPIC_OCID" \
        --title "$title" \
        --body "$body" 2>&1)"; then
    log INFO "Notification sent: $title"
    return 0
  fi
  log ERROR "NOTIFICATION FAILED. The run result below was not emailed. Check the ONS topic OCID and the 'use ons-topics' policy."
  log ERROR "ONS response: $(printf '%s' "$publish_output" | tr '\n' ' ' | cut -c1-500)"
  return 1
}

# Assemble the body shared by success and failure email.
run_report() {
  local outcome="$1"
  local rc="$2"
  local end_epoch elapsed
  end_epoch="$(date -u +%s)"
  elapsed=$(( end_epoch - START_EPOCH ))
  {
    printf 'CD3 backup %s\n\n' "$outcome"
    [[ -n "$NOTIFY_ENVIRONMENT" ]] && printf 'Environment:    %s\n' "$NOTIFY_ENVIRONMENT"
    printf 'Host:           %s\n' "$HOST_NAME"
    printf 'Instance:       %s\n' "${INSTANCE_DISPLAY_NAME:-${INSTANCE_BACKUP_NAME:-unknown}}"
    printf 'Instance OCID:  %s\n' "${INSTANCE_OCID:-not yet discovered}"
    printf 'Region:         %s\n' "${OCI_REGION:-not yet discovered}"
    printf 'Mode:           %s\n' "${MODE:-unknown}"
    printf 'Backup class:   %s\n' "${BACKUP_CLASS:-unknown}"
    [[ -n "$PRE_CHANGE_LABEL" ]] && printf 'Change label:   %s\n' "$PRE_CHANGE_LABEL"
    printf 'Backup ID:      %s\n' "${BACKUP_ID:-not assigned}"
    printf 'Started (UTC):  %s\n' "$START_TIME"
    printf 'Duration:       %s min %s sec\n' "$(( elapsed / 60 ))" "$(( elapsed % 60 ))"
    printf 'Script version: %s\n' "$SCRIPT_VERSION"
    printf '\n'
    if [[ "$outcome" == "SUCCEEDED" ]]; then
      if [[ -n "${volume_backup_records:-}" && "${volume_backup_records:-[]}" != "[]" ]]; then
        printf 'OCI volume backups created:\n'
        jq -r '.[] | "  - \(.type): \(.id)"' <<<"$volume_backup_records" 2>/dev/null || printf '  %s\n' "$volume_backup_records"
      else
        printf 'OCI volume backups created: none (config-only run)\n'
      fi
      [[ -n "${object_directory:-}" ]] && printf '\nObject Storage directory:\n  %s\n' "$object_directory"
      printf '\nVerify this backup with:\n'
      printf '  sudo -u %s /opt/cd3-backup/verify_cd3_backup.sh --config %s --backup-id %s\n' \
        "$(id -un)" "$CONFIG_FILE" "${BACKUP_ID:-<id>}"
    else
      printf 'Exit code:      %s\n' "$rc"
      printf 'Failed during:  %s\n' "$RUN_STAGE"
      printf 'Reason:         %s\n' "${LAST_ERROR:-the command above returned a non-zero status}"
      printf '\nNO BACKUP WAS COMPLETED FOR THIS RUN.\n'
      [[ -n "$WORK_DIR" ]] && printf '\nDiagnostic files retained at:\n  %s\n' "$WORK_DIR"
      printf '\nInvestigate with:\n'
      printf '  sudo journalctl -u cd3-backup.service -n 200 --no-pager\n'
    fi
  } 2>/dev/null
}

send_run_notification() {
  local rc="$1"
  is_true "$NOTIFICATION_SENT" && return 0
  NOTIFICATION_SENT=true

  if [[ -z "$ONS_TOPIC_OCID" ]]; then
    (( rc == 0 )) || log WARN "No ONS_TOPIC_OCID is configured, so no failure email was sent."
    return 0
  fi
  if ! is_true "$NOTIFY_READY"; then
    log ERROR "Failed before OCI authentication was usable, so no email could be sent. The systemd OnFailure unit is the backstop for this case."
    return 0
  fi
  if is_true "$DRY_RUN" && ! is_true "$NOTIFY_ON_DRY_RUN"; then
    return 0
  fi

  local env_tag=""
  [[ -n "$NOTIFY_ENVIRONMENT" ]] && env_tag=" $NOTIFY_ENVIRONMENT"
  if (( rc == 0 )); then
    is_true "$NOTIFY_ON_SUCCESS" || return 0
    publish_message \
      "$NOTIFY_SUBJECT_PREFIX${env_tag} SUCCESS - ${INSTANCE_BACKUP_NAME:-cd3} - ${BACKUP_CLASS:-scheduled}" \
      "$(run_report SUCCEEDED "$rc")" || true
  else
    is_true "$NOTIFY_ON_FAILURE" || return 0
    publish_message \
      "$NOTIFY_SUBJECT_PREFIX${env_tag} FAILED - ${INSTANCE_BACKUP_NAME:-cd3} - ${RUN_STAGE}" \
      "$(run_report FAILED "$rc")" || true
  fi
}

WORK_DIR=""

# ERR fires for a command that returns non-zero; it records context and lets the
# EXIT trap do the reporting. EXIT is what guarantees a notification, because
# "die" calls exit directly and never triggers ERR - in 1.0.1 that meant every
# safety-guard refusal completed silently with no email at all.
on_error() {
  local rc=$?
  [[ -n "$LAST_ERROR" ]] || LAST_ERROR="command failed: ${BASH_COMMAND:-unknown} (exit $rc)"
  return 0
}

on_exit() {
  local rc=$?
  trap - ERR EXIT
  set +e
  if (( rc != 0 )); then
    log ERROR "CD3 backup failed with exit code $rc during: $RUN_STAGE"
    [[ -n "$WORK_DIR" ]] && log ERROR "Diagnostic files were retained at: $WORK_DIR"
  fi
  send_run_notification "$rc"
  exit "$rc"
}

on_signal() {
  local sig="$1"
  LAST_ERROR="the backup was terminated by SIG$sig (systemd TimeoutStartSec, a reboot, or an operator)"
  log ERROR "$LAST_ERROR"
  exit 143
}

trap on_error ERR
trap on_exit EXIT
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT

stage "Validating OCI authentication in region $OCI_REGION."
oci_cmd os ns get >/dev/null

# From here on the script can publish, so every later failure reaches the inbox.
NOTIFY_READY=true

if [[ -n "$ONS_TOPIC_OCID" ]]; then
  stage "Validating the OCI Notifications topic."
  if topic_json="$(oci_cmd ons topic get --topic-id "$ONS_TOPIC_OCID" 2>&1)"; then
    log INFO "Notification topic: $(jq -r '.data.name // "unknown"' <<<"$topic_json" 2>/dev/null || printf 'unknown')"
  else
    log ERROR "The configured ONS_TOPIC_OCID could not be read. Alerting for this run is broken."
    log ERROR "ONS response: $(printf '%s' "$topic_json" | tr '\n' ' ' | cut -c1-300)"
    if is_true "$REQUIRE_NOTIFICATION_TOPIC"; then
      die "REQUIRE_NOTIFICATION_TOPIC is true and the topic is unusable. Refusing to run a backup nobody would be told about."
    fi
    ONS_TOPIC_OCID=""
  fi
elif is_true "$REQUIRE_NOTIFICATION_TOPIC"; then
  die "REQUIRE_NOTIFICATION_TOPIC is true but ONS_TOPIC_OCID is empty."
fi

if is_true "$TEST_NOTIFICATION"; then
  [[ -n "$ONS_TOPIC_OCID" ]] || die "--test-notification needs a working ONS_TOPIC_OCID."
  stage "Sending a test notification."
  env_tag=""
  [[ -n "$NOTIFY_ENVIRONMENT" ]] && env_tag=" $NOTIFY_ENVIRONMENT"
  publish_message "$NOTIFY_SUBJECT_PREFIX${env_tag} TEST - ${INSTANCE_BACKUP_NAME:-cd3}" \
"This is a test message from the CD3 backup notification path. No backup was run.

Host:           $HOST_NAME
Instance:       ${INSTANCE_BACKUP_NAME:-unknown}
Region:         $OCI_REGION
Sent (UTC):     $START_TIME
Script version: $SCRIPT_VERSION

If you received this, success and failure email for CD3 backups will reach you
at this address. If you did NOT receive it, the email subscription is probably
still PENDING - confirm it from the link OCI emailed when it was created." \
    || die "The test notification could not be published."
  NOTIFICATION_SENT=true
  log INFO "Test notification published. Confirm it arrived before relying on backup alerting."
  exit 0
fi

if [[ "$MODE" != "volume-only" ]]; then
  oci_cmd os bucket get --bucket-name "$BACKUP_BUCKET" >/dev/null
fi

timestamp="$(date -u +'%Y%m%dT%H%M%SZ')"
suffix="$(printf '%s' "$timestamp-$$-$RANDOM" | sha256sum | cut -c1-8)"
BACKUP_ID="$timestamp-$suffix"
if [[ -n "$PRE_CHANGE_LABEL" ]]; then
  safe_change="$(sanitize_name "$PRE_CHANGE_LABEL")"
  [[ -n "$safe_change" ]] || die "The pre-change label is not usable after sanitization."
  BACKUP_ID="$BACKUP_ID-$safe_change"
fi

WORK_DIR="$(mktemp -d "$WORK_ROOT/$BACKUP_ID.XXXXXX")"
chmod 700 "$WORK_DIR"
META_DIR="$WORK_DIR/backup-metadata"
INVENTORY_DIR="$META_DIR/inventory"
ORM_DIR="$META_DIR/resource-manager"
mkdir -p "$INVENTORY_DIR" "$ORM_DIR"

stage "Capturing the instance and volume inventory."
oci_cmd compute instance get --instance-id "$INSTANCE_OCID" >"$INVENTORY_DIR/instance.json"
if [[ -z "$INSTANCE_DISPLAY_NAME" ]]; then
  INSTANCE_DISPLAY_NAME="$(jq -r '.data."display-name" // empty' "$INVENTORY_DIR/instance.json")"
fi
oci_cmd compute boot-volume-attachment list \
  --availability-domain "$AVAILABILITY_DOMAIN" \
  --compartment-id "$INSTANCE_COMPARTMENT_OCID" \
  --instance-id "$INSTANCE_OCID" --all >"$INVENTORY_DIR/boot-volume-attachments.json"
oci_cmd compute volume-attachment list \
  --compartment-id "$INSTANCE_COMPARTMENT_OCID" \
  --instance-id "$INSTANCE_OCID" --all >"$INVENTORY_DIR/block-volume-attachments.json"
oci_cmd compute vnic-attachment list \
  --compartment-id "$INSTANCE_COMPARTMENT_OCID" \
  --instance-id "$INSTANCE_OCID" --all >"$INVENTORY_DIR/vnic-attachments.json"

BOOT_VOLUME_OCID="$(jq -r '[.data[]? | select((."lifecycle-state" // "") == "ATTACHED") | ."boot-volume-id"] | map(select(. != null)) | first // empty' "$INVENTORY_DIR/boot-volume-attachments.json")"
[[ -n "$BOOT_VOLUME_OCID" ]] || die "No attached boot volume was found for the instance."
read_lines_or_die BLOCK_VOLUME_OCIDS "the block-volume attachment list" \
  jq -r '.data[]? | select((."lifecycle-state" // "") == "ATTACHED") | ."volume-id" // empty' "$INVENTORY_DIR/block-volume-attachments.json"
ALL_VOLUME_OCIDS=("$BOOT_VOLUME_OCID" ${BLOCK_VOLUME_OCIDS[@]+"${BLOCK_VOLUME_OCIDS[@]}"})

oci_cmd bv boot-volume get --boot-volume-id "$BOOT_VOLUME_OCID" >"$INVENTORY_DIR/boot-volume.json"
mkdir -p "$INVENTORY_DIR/block-volumes"
for volume_id in ${BLOCK_VOLUME_OCIDS[@]+"${BLOCK_VOLUME_OCIDS[@]}"}; do
  volume_key="$(printf '%s' "$volume_id" | sha256sum | cut -c1-12)"
  oci_cmd bv volume get --volume-id "$volume_id" >"$INVENTORY_DIR/block-volumes/$volume_key.json"
done

mkdir -p "$INVENTORY_DIR/vnics" "$INVENTORY_DIR/subnets"
read_lines_or_die VNIC_OCIDS "the VNIC attachment list" \
  jq -r '.data[]? | ."vnic-id" // empty' "$INVENTORY_DIR/vnic-attachments.json"
for vnic_id in ${VNIC_OCIDS[@]+"${VNIC_OCIDS[@]}"}; do
  vnic_key="$(printf '%s' "$vnic_id" | sha256sum | cut -c1-12)"
  vnic_file="$INVENTORY_DIR/vnics/$vnic_key.json"
  oci_cmd network vnic get --vnic-id "$vnic_id" >"$vnic_file"
  subnet_id="$(jq -r '.data."subnet-id" // empty' "$vnic_file")"
  if [[ -n "$subnet_id" ]]; then
    subnet_key="$(printf '%s' "$subnet_id" | sha256sum | cut -c1-12)"
    if [[ ! -f "$INVENTORY_DIR/subnets/$subnet_key.json" ]]; then
      oci_cmd network subnet get --subnet-id "$subnet_id" >"$INVENTORY_DIR/subnets/$subnet_key.json"
    fi
  fi
done

{
  printf 'backup_script_version=%s\n' "$SCRIPT_VERSION"
  printf 'oci_cli_version=%s\n' "$(oci --version 2>&1)"
  printf 'kernel=%s\n' "$(uname -a)"
  command -v terraform >/dev/null 2>&1 && printf 'terraform_version=%s\n' "$(terraform version -json 2>/dev/null | jq -c . 2>/dev/null || terraform version 2>&1 | head -1)"
  command -v python3 >/dev/null 2>&1 && printf 'python_version=%s\n' "$(python3 --version 2>&1)"
} >"$META_DIR/software-versions.txt"

existing_cd3_paths=()
if [[ "$MODE" != "volume-only" ]]; then
  for configured_path in ${CD3_PATHS[@]+"${CD3_PATHS[@]}"}; do
    [[ -n "$configured_path" ]] || continue
    [[ "$configured_path" == /* && "$configured_path" != "/" ]] || die "CD3 path must be a specific absolute path: $configured_path"
    if [[ -e "$configured_path" ]]; then
      resolved_path="$(realpath -e "$configured_path")"
      [[ "$resolved_path" != "/" ]] || die "Refusing to archive the filesystem root."
      existing_cd3_paths+=("$resolved_path")
    else
      log WARN "Configured CD3 path does not exist and will be skipped: $configured_path"
    fi
  done
  if (( ${#existing_cd3_paths[@]} == 0 )) && is_true "$REQUIRE_AT_LEAST_ONE_CD3_PATH"; then
    die "None of the configured CD3_PATHS exist. Update the configuration before continuing."
  fi
fi

stage "Checking for active CD3 or Terraform changes."
active_processes="$(ps -eo pid=,args= 2>/dev/null | grep -E "$ACTIVE_PROCESS_PATTERN" | grep -v -E 'grep -E|backup_cd3_instance' || true)"
[[ -z "$active_processes" ]] || die "A Terraform or CD3 change process appears to be active. Backup was not started."
for cd3_path in ${existing_cd3_paths[@]+"${existing_cd3_paths[@]}"}; do
  lock_path="$(find "$cd3_path" -type f -name '.terraform.tfstate.lock.info' -print -quit 2>/dev/null || true)"
  [[ -z "$lock_path" ]] || die "Terraform state lock detected: $lock_path"
done

stack_ids_json="$(jq -n '$ARGS.positional' --args ${ORM_STACK_OCIDS[@]+"${ORM_STACK_OCIDS[@]}"})"
for stack_id in ${ORM_STACK_OCIDS[@]+"${ORM_STACK_OCIDS[@]}"}; do
  [[ -n "$stack_id" ]] || continue
  stack_key="$(printf '%s' "$stack_id" | sha256sum | cut -c1-12)"
  stack_dir="$ORM_DIR/$stack_key"
  mkdir -p "$stack_dir"
  oci_cmd resource-manager stack get --stack-id "$stack_id" >"$stack_dir/stack.json"
  oci_cmd resource-manager job list --stack-id "$stack_id" --all >"$stack_dir/jobs.json"
  if jq -e '.data[]? | select((."lifecycle-state" // "") == "ACCEPTED" or (."lifecycle-state" // "") == "IN_PROGRESS")' "$stack_dir/jobs.json" >/dev/null; then
    die "Resource Manager stack $stack_id has an active job."
  fi
done

if [[ -n "$VOLUME_GROUP_OCID" && "$MODE" != "config-only" ]]; then
  oci_cmd bv volume-group get --volume-group-id "$VOLUME_GROUP_OCID" >"$INVENTORY_DIR/volume-group.json"
  for volume_id in ${ALL_VOLUME_OCIDS[@]+"${ALL_VOLUME_OCIDS[@]}"}; do
    if ! jq -e --arg id "$volume_id" '.data."volume-ids" | index($id)' "$INVENTORY_DIR/volume-group.json" >/dev/null; then
      die "Configured volume group does not contain attached volume: $volume_id"
    fi
  done
elif (( ${#ALL_VOLUME_OCIDS[@]} > 1 )) && [[ "$MODE" != "config-only" ]] && ! is_true "$ALLOW_INDIVIDUAL_VOLUME_BACKUPS"; then
  die "The instance has multiple volumes but VOLUME_GROUP_OCID is empty. Run setup_cd3_volume_group.sh first, or explicitly enable individual backups."
fi

if is_true "$DRY_RUN"; then
  log INFO "Dry run passed. No OCI backup or Object Storage object was created."
  log INFO "Instance: $INSTANCE_OCID"
  log INFO "Region: $OCI_REGION; availability domain: $AVAILABILITY_DOMAIN"
  log INFO "Attached volumes: ${#ALL_VOLUME_OCIDS[@]}; CD3 paths found: ${#existing_cd3_paths[@]}; Resource Manager stacks: ${#ORM_STACK_OCIDS[@]}"
  if is_true "$APPLY_RETENTION_PERIOD"; then
    log INFO "Retention period this script will send: $(build_retention_json)"
    skeleton="$(oci bv volume-group-backup create --generate-param-json-input retention-period 2>/dev/null || true)"
    if [[ -n "$skeleton" ]]; then
      log INFO "Retention shape expected by this OCI CLI: $(jq -c . <<<"$skeleton" 2>/dev/null || printf '%s' "$skeleton")"
      log INFO "If the two lines above disagree, set RETENTION_PERIOD_JSON in the configuration to match this CLI."
    fi
  fi
  rm -rf -- "$WORK_DIR"
  WORK_DIR=""
  exit 0
fi

stage "Exporting Resource Manager stack configuration and state."
for stack_id in ${ORM_STACK_OCIDS[@]+"${ORM_STACK_OCIDS[@]}"}; do
  [[ -n "$stack_id" ]] || continue
  stack_key="$(printf '%s' "$stack_id" | sha256sum | cut -c1-12)"
  stack_dir="$ORM_DIR/$stack_key"
  oci_cmd resource-manager stack get-stack-tf-config --stack-id "$stack_id" --file "$stack_dir/terraform-config.zip"
  oci_cmd resource-manager stack get-stack-tf-state --stack-id "$stack_id" --file "$stack_dir/terraform-state.json"
done

retention_json="$(build_retention_json)"
freeform_tags="$(jq -cn \
  --argjson base "$FREEFORM_TAGS_JSON" \
  --arg id "$BACKUP_ID" \
  --arg class "$BACKUP_CLASS" \
  '$base + {BackupId:$id,BackupClass:$class}')"
# Common arguments accepted by every backup-create command.
backup_args=(
  --type "$BACKUP_TYPE"
  --freeform-tags "$freeform_tags"
  --wait-for-state AVAILABLE
  --max-wait-seconds "$BACKUP_WAIT_SECONDS"
  --wait-interval-seconds 30
)
if [[ -n "$DEFINED_TAGS_JSON" ]]; then
  backup_args+=(--defined-tags "$DEFINED_TAGS_JSON")
fi

# "oci bv boot-volume-backup create" does not accept --retention-period, while
# "bv backup create" and "bv volume-group-backup create" do. Only add it where
# it is valid; boot-volume backups get their retention applied after creation.
retention_args=()
if is_true "$APPLY_RETENTION_PERIOD"; then
  retention_args=(--retention-period "$retention_json")
fi

apply_boot_backup_retention() {
  local backup_id="$1"
  is_true "$APPLY_RETENTION_PERIOD" || return 0
  if oci_cmd bv boot-volume-backup update \
      --boot-volume-backup-id "$backup_id" \
      --retention-period "$retention_json" \
      --force >/dev/null; then
    log INFO "Applied a $RETENTION_DAYS-day retention period to boot-volume backup $backup_id."
  else
    log WARN "Could not apply a retention period to boot-volume backup $backup_id. The backup exists but will not expire automatically; delete it manually or use a volume group."
  fi
}

volume_backup_records='[]'
if [[ "$MODE" != "config-only" ]]; then
  sync
  if [[ -n "$VOLUME_GROUP_OCID" ]]; then
    stage "Creating coordinated OCI volume-group backup."
    response_file="$META_DIR/volume-group-backup-response.json"
    oci_cmd bv volume-group-backup create \
      --volume-group-id "$VOLUME_GROUP_OCID" \
      --display-name "cd3-$BACKUP_ID" \
      "${backup_args[@]}" ${retention_args[@]+"${retention_args[@]}"} >"$response_file"
    backup_ocid="$(jq -r '.data.id // empty' "$response_file")"
    [[ -n "$backup_ocid" ]] || die "OCI did not return a volume-group backup OCID."
    volume_backup_records="$(jq -cn --arg id "$backup_ocid" --arg source "$VOLUME_GROUP_OCID" '[{type:"volume-group-backup",id:$id,sourceId:$source,state:"AVAILABLE"}]')"
  else
    stage "Creating OCI boot-volume backup."
    response_file="$META_DIR/boot-volume-backup-response.json"
    oci_cmd bv boot-volume-backup create \
      --boot-volume-id "$BOOT_VOLUME_OCID" \
      --display-name "cd3-boot-$BACKUP_ID" \
      "${backup_args[@]}" >"$response_file"
    backup_ocid="$(jq -r '.data.id // empty' "$response_file")"
    [[ -n "$backup_ocid" ]] || die "OCI did not return a boot-volume backup OCID."
    apply_boot_backup_retention "$backup_ocid"
    volume_backup_records="$(jq -cn --arg id "$backup_ocid" --arg source "$BOOT_VOLUME_OCID" '[{type:"boot-volume-backup",id:$id,sourceId:$source,state:"AVAILABLE"}]')"
    for volume_id in ${BLOCK_VOLUME_OCIDS[@]+"${BLOCK_VOLUME_OCIDS[@]}"}; do
      volume_key="$(printf '%s' "$volume_id" | sha256sum | cut -c1-12)"
      response_file="$META_DIR/block-volume-backup-$volume_key-response.json"
      oci_cmd bv backup create \
        --volume-id "$volume_id" \
        --display-name "cd3-data-$volume_key-$BACKUP_ID" \
        "${backup_args[@]}" ${retention_args[@]+"${retention_args[@]}"} >"$response_file"
      backup_ocid="$(jq -r '.data.id // empty' "$response_file")"
      [[ -n "$backup_ocid" ]] || die "OCI did not return a block-volume backup OCID for $volume_id."
      volume_backup_records="$(jq -c --arg id "$backup_ocid" --arg source "$volume_id" '. + [{type:"volume-backup",id:$id,sourceId:$source,state:"AVAILABLE"}]' <<<"$volume_backup_records")"
    done
  fi
fi

paths_json="$(jq -n '$ARGS.positional' --args "${existing_cd3_paths[@]}")"
created_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
year="${timestamp:0:4}"
month="${timestamp:4:2}"
object_directory="$OBJECT_PREFIX/$INSTANCE_BACKUP_NAME/$BACKUP_CLASS/$year/$month/$BACKUP_ID"

jq -n \
  --arg version "$SCRIPT_VERSION" \
  --arg backupId "$BACKUP_ID" \
  --arg createdAt "$created_at" \
  --arg mode "$MODE" \
  --arg backupType "$BACKUP_TYPE" \
  --arg backupClass "$BACKUP_CLASS" \
  --arg changeLabel "$PRE_CHANGE_LABEL" \
  --argjson retentionDays "$RETENTION_DAYS" \
  --arg instanceId "$INSTANCE_OCID" \
  --arg instanceName "$INSTANCE_DISPLAY_NAME" \
  --arg backupName "$INSTANCE_BACKUP_NAME" \
  --arg compartmentId "$INSTANCE_COMPARTMENT_OCID" \
  --arg region "$OCI_REGION" \
  --arg availabilityDomain "$AVAILABILITY_DOMAIN" \
  --arg bootVolumeId "$BOOT_VOLUME_OCID" \
  --arg volumeGroupId "$VOLUME_GROUP_OCID" \
  --arg objectDirectory "$object_directory" \
  --argjson cd3Paths "$paths_json" \
  --argjson ormStackIds "$stack_ids_json" \
  --argjson volumeBackups "$volume_backup_records" \
  '{schemaVersion:1,scriptVersion:$version,status:"SUCCEEDED",backupId:$backupId,createdAt:$createdAt,mode:$mode,backupType:$backupType,backupClass:$backupClass,changeLabel:$changeLabel,retentionDays:$retentionDays,instance:{id:$instanceId,displayName:$instanceName,backupName:$backupName,compartmentId:$compartmentId,region:$region,availabilityDomain:$availabilityDomain},storage:{bootVolumeId:$bootVolumeId,volumeGroupId:$volumeGroupId,volumeBackups:$volumeBackups},cd3Paths:$cd3Paths,resourceManagerStackIds:$ormStackIds,objectDirectory:$objectDirectory}' \
  >"$META_DIR/backup-manifest.json"

upload_files=()
archive_sha256=""
if [[ "$MODE" != "volume-only" ]]; then
  stage "Creating the logical CD3 archive (plaintext locally, encrypted at rest by Object Storage once uploaded)."
  archive="$WORK_DIR/cd3-backup.tar.gz"
  tar_command=(tar -czf "$archive")
  for pattern in ${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}; do
    [[ -n "$pattern" ]] && tar_command+=(--exclude="$pattern")
  done
  if (( ${#existing_cd3_paths[@]} > 0 )); then
    relative_paths=()
    for path in ${existing_cd3_paths[@]+"${existing_cd3_paths[@]}"}; do
      relative_paths+=("${path#/}")
    done
    tar_command+=(-C / "${relative_paths[@]}")
  fi
  tar_command+=(-C "$WORK_DIR" backup-metadata)
  "${tar_command[@]}"

  archive_sha256="$(sha256sum "$archive" | awk '{print $1}')"
  printf '%s  %s\n' "$archive_sha256" "$(basename "$archive")" >"$WORK_DIR/SHA256SUMS"
  upload_files+=("$archive" "$WORK_DIR/SHA256SUMS")
fi

# The manifest is always uploaded when a bucket is available, including in
# volume-only mode. Without it verify_cd3_backup.sh has no record to check and
# the volume-backup OCIDs would survive only in this run's log output.
if [[ -n "$BACKUP_BUCKET" ]]; then
  jq -n \
    --arg status SUCCEEDED \
    --arg backupId "$BACKUP_ID" \
    --arg mode "$MODE" \
    --arg archiveObject "$([[ "$MODE" != "volume-only" ]] && printf '%s' "$object_directory/cd3-backup.tar.gz" || printf '')" \
    --arg manifestObject "$object_directory/backup-manifest.json" \
    --arg sha256 "$archive_sha256" \
    --argjson volumeBackups "$volume_backup_records" \
    '{status:$status,backupId:$backupId,mode:$mode,archiveObject:$archiveObject,manifestObject:$manifestObject,sha256:$sha256,volumeBackups:$volumeBackups}' \
    >"$WORK_DIR/backup-result.json"
  upload_files+=("$META_DIR/backup-manifest.json" "$WORK_DIR/backup-result.json")

  upload_metadata="$(jq -cn --arg id "$BACKUP_ID" --arg sha "$archive_sha256" '{backupId:$id,archiveSha256:$sha}')"
  stage "Uploading and checksum-verifying the backup record."
  for local_file in "${upload_files[@]}"; do
    object_name="$object_directory/$(basename "$local_file")"
    oci_cmd os object put \
      --bucket-name "$BACKUP_BUCKET" \
      --name "$object_name" \
      --file "$local_file" \
      --metadata "$upload_metadata" \
      --no-overwrite \
      --verify-checksum >/dev/null
    oci_cmd os object head --bucket-name "$BACKUP_BUCKET" --name "$object_name" >/dev/null
  done
else
  log WARN "BACKUP_BUCKET is not set, so no backup manifest was uploaded. This backup cannot be checked by verify_cd3_backup.sh."
fi

log INFO "CD3 backup completed successfully. Backup ID: $BACKUP_ID"
if [[ "$MODE" != "config-only" ]]; then
  log INFO "OCI backup records: $(jq -c . <<<"$volume_backup_records")"
fi
if [[ -n "$BACKUP_BUCKET" ]]; then
  log INFO "Object Storage directory: $object_directory"
fi

if ! is_true "$KEEP_LOCAL_COPY"; then
  rm -rf -- "$WORK_DIR"
  WORK_DIR=""
fi
