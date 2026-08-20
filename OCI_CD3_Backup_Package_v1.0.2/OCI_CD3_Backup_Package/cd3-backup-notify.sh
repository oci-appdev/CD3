#!/usr/bin/env bash
# Publish a CD3 backup notification to the configured OCI Notifications topic.
#
# Two uses:
#   1. systemd OnFailure= backstop. If backup_cd3_instance.sh dies so early or so
#      hard that it cannot email (missing interpreter, OOM kill, SIGKILL after
#      TimeoutStartSec), systemd still runs this and the failure reaches the inbox.
#   2. Operators proving that email delivery works, without running a backup.
set -Eeuo pipefail
umask 077

SCRIPT_VERSION="1.0.2"
CONFIG_FILE="/etc/cd3-backup/cd3-backup.conf"
STATE="failed"
MESSAGE=""
UNIT=""

usage() {
  cat <<'USAGE'
Usage: cd3-backup-notify.sh [--config FILE] [--state STATE] [--message TEXT] [--unit NAME]

Options:
  --config FILE     Configuration file (default: /etc/cd3-backup/cd3-backup.conf)
  --state STATE     failed (default), succeeded, or test
  --message TEXT    Extra detail to include in the body
  --unit NAME       systemd unit that triggered this, quoted in the message
  --help            Show this help

Exit codes:
  0  the message was published
  1  the message could not be published
USAGE
}

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
is_true() { case "${1,,}" in true|yes|1) return 0 ;; *) return 1 ;; esac; }
sanitize_name() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//' | cut -c1-100; }

args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --config) ((i+1<${#args[@]})) || die "--config requires a file."; CONFIG_FILE="${args[$((i+1))]}"; ((i+=1)) ;;
    --state) ((i+1<${#args[@]})) || die "--state requires a value."; STATE="${args[$((i+1))]}"; ((i+=1)) ;;
    --message) ((i+1<${#args[@]})) || die "--message requires text."; MESSAGE="${args[$((i+1))]}"; ((i+=1)) ;;
    --unit) ((i+1<${#args[@]})) || die "--unit requires a name."; UNIT="${args[$((i+1))]}"; ((i+=1)) ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: ${args[$i]}" ;;
  esac
done

case "$STATE" in
  failed|succeeded|test) ;;
  *) die "--state must be failed, succeeded, or test." ;;
esac

[[ -r "$CONFIG_FILE" ]] || die "Configuration file is not readable: $CONFIG_FILE"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
for cmd in oci jq curl; do command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"; done

ONS_TOPIC_OCID="${ONS_TOPIC_OCID:-}"
[[ -n "$ONS_TOPIC_OCID" ]] || die "ONS_TOPIC_OCID is not set in $CONFIG_FILE."
OCI_REGION="${OCI_REGION:-}"
OCI_AUTH_MODE="${OCI_AUTH_MODE:-instance_principal}"
USE_REALM_SPECIFIC_ENDPOINT="${USE_REALM_SPECIFIC_ENDPOINT:-true}"
INSTANCE_BACKUP_NAME="${INSTANCE_BACKUP_NAME:-}"
NOTIFY_SUBJECT_PREFIX="${NOTIFY_SUBJECT_PREFIX:-[CD3 Backup]}"
NOTIFY_ENVIRONMENT="${NOTIFY_ENVIRONMENT:-}"

metadata='{}'
if [[ -z "$OCI_REGION" || -z "$INSTANCE_BACKUP_NAME" ]]; then
  metadata="$(curl -fsS --connect-timeout 3 --max-time 10 -H 'Authorization: Bearer Oracle' 'http://169.254.169.254/opc/v2/instance/' 2>/dev/null || printf '{}')"
fi
OCI_REGION="${OCI_REGION:-$(jq -r '.canonicalRegionName // .region // empty' <<<"$metadata")}"
INSTANCE_BACKUP_NAME="${INSTANCE_BACKUP_NAME:-$(jq -r '.displayName // empty' <<<"$metadata")}"
INSTANCE_BACKUP_NAME="$(sanitize_name "${INSTANCE_BACKUP_NAME:-cd3-instance}")"
[[ -n "$OCI_REGION" ]] || die "OCI_REGION could not be determined."

oci_cmd() {
  local command=(oci "$@")
  [[ -z "$OCI_AUTH_MODE" ]] || command+=(--auth "$OCI_AUTH_MODE")
  command+=(--region "$OCI_REGION")
  is_true "$USE_REALM_SPECIFIC_ENDPOINT" && command+=(--realm-specific-endpoint)
  "${command[@]}"
}

host_name="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown-host')"
now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
env_tag=""
[[ -n "$NOTIFY_ENVIRONMENT" ]] && env_tag=" $NOTIFY_ENVIRONMENT"

case "$STATE" in
  failed)
    title="$NOTIFY_SUBJECT_PREFIX${env_tag} FAILED - $INSTANCE_BACKUP_NAME - run did not complete"
    headline="The CD3 backup run did not complete."
    detail="This message came from the systemd failure handler, not from the backup
script itself. That means the run failed before or beyond the point where the
script could report for itself - for example it was killed on TimeoutStartSec,
the host rebooted mid-run, or the script could not start at all.

NO BACKUP WAS COMPLETED FOR THIS RUN."
    ;;
  succeeded)
    title="$NOTIFY_SUBJECT_PREFIX${env_tag} SUCCESS - $INSTANCE_BACKUP_NAME"
    headline="The CD3 backup run completed."
    detail=""
    ;;
  test)
    title="$NOTIFY_SUBJECT_PREFIX${env_tag} TEST - $INSTANCE_BACKUP_NAME"
    headline="Test message from the CD3 backup notification path."
    detail="No backup was run. If you received this, CD3 backup alerts will reach you
at this address. If you did not, the email subscription is probably still
PENDING - confirm it from the link OCI emailed when it was created."
    ;;
esac

body="$headline

Host:           $host_name
Instance:       $INSTANCE_BACKUP_NAME
Region:         $OCI_REGION
Time (UTC):     $now"
[[ -n "$NOTIFY_ENVIRONMENT" ]] && body="$body
Environment:    $NOTIFY_ENVIRONMENT"
[[ -n "$UNIT" ]] && body="$body
Unit:           $UNIT"
body="$body
Notifier:       cd3-backup-notify.sh $SCRIPT_VERSION"
[[ -n "$detail" ]] && body="$body

$detail"
[[ -n "$MESSAGE" ]] && body="$body

$MESSAGE"
if [[ "$STATE" == "failed" ]]; then
  body="$body

Investigate with:
  sudo journalctl -u cd3-backup.service -n 200 --no-pager
  sudo systemctl status cd3-backup.service"
fi

if output="$(oci_cmd ons message publish --topic-id "$ONS_TOPIC_OCID" --title "$title" --body "$body" 2>&1)"; then
  printf 'Notification published: %s\n' "$title"
  exit 0
fi
printf 'ERROR: could not publish the notification.\n' >&2
printf 'ONS response: %s\n' "$(printf '%s' "$output" | tr '\n' ' ' | cut -c1-500)" >&2
exit 1
