#!/usr/bin/env bash
# Create the OCI Notifications topic and email subscriptions for CD3 backup alerts.
# Discovery-only by default; --execute makes changes. Never deletes anything.
set -Eeuo pipefail
umask 077

SCRIPT_VERSION="1.0.2"
CONFIG_FILE="/etc/cd3-backup/cd3-backup.conf"
EXECUTE=false
TOPIC_NAME="cd3-backup-alerts"
COMPARTMENT_OCID=""
EMAILS=()

usage() {
  cat <<'USAGE'
Usage: setup_cd3_notifications.sh --email ADDRESS [--email ADDRESS ...] [options]

Options:
  --config FILE          Configuration file (default: /etc/cd3-backup/cd3-backup.conf)
  --email ADDRESS        Address to subscribe. Repeat for several. A distribution
                         list alias is fine and is the better choice for a team.
  --topic-name NAME      Topic display name (default: cd3-backup-alerts)
  --compartment-id OCID  Compartment for the topic (default: the instance compartment)
  --execute              Create the topic and subscriptions; otherwise show the plan
  --help                 Show this help

Reuses an existing topic of the same name rather than creating a duplicate, and
skips addresses that are already subscribed, so it is safe to re-run.

Every new email subscription starts in PENDING state. OCI emails each address a
confirmation link valid for three days; until someone clicks it, that address
receives nothing. Confirm, then prove delivery end to end with:
  backup_cd3_instance.sh --config <file> --test-notification
USAGE
}

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
is_true() { case "${1,,}" in true|yes|1) return 0 ;; *) return 1 ;; esac; }

args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --config) ((i+1<${#args[@]})) || die "--config requires a file."; CONFIG_FILE="${args[$((i+1))]}"; ((i+=1)) ;;
    --email) ((i+1<${#args[@]})) || die "--email requires an address."; EMAILS+=("${args[$((i+1))]}"); ((i+=1)) ;;
    --topic-name) ((i+1<${#args[@]})) || die "--topic-name requires a value."; TOPIC_NAME="${args[$((i+1))]}"; ((i+=1)) ;;
    --compartment-id) ((i+1<${#args[@]})) || die "--compartment-id requires an OCID."; COMPARTMENT_OCID="${args[$((i+1))]}"; ((i+=1)) ;;
    --execute) EXECUTE=true ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: ${args[$i]}" ;;
  esac
done

(( ${#EMAILS[@]} > 0 )) || die "At least one --email address is required."
for address in "${EMAILS[@]}"; do
  [[ "$address" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "Not a valid email address: $address"
done
[[ "$TOPIC_NAME" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Topic name may contain only letters, numbers, dots, underscores, and hyphens."

[[ -r "$CONFIG_FILE" ]] || die "Configuration file is not readable: $CONFIG_FILE"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
for cmd in oci jq curl; do command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"; done

OCI_REGION="${OCI_REGION:-}"
OCI_AUTH_MODE="${OCI_AUTH_MODE:-instance_principal}"
USE_REALM_SPECIFIC_ENDPOINT="${USE_REALM_SPECIFIC_ENDPOINT:-true}"
INSTANCE_COMPARTMENT_OCID="${INSTANCE_COMPARTMENT_OCID:-}"

metadata='{}'
if [[ -z "$OCI_REGION" || -z "$INSTANCE_COMPARTMENT_OCID" ]]; then
  metadata="$(curl -fsS --connect-timeout 3 --max-time 10 -H 'Authorization: Bearer Oracle' 'http://169.254.169.254/opc/v2/instance/' 2>/dev/null || printf '{}')"
fi
OCI_REGION="${OCI_REGION:-$(jq -r '.canonicalRegionName // .region // empty' <<<"$metadata")}"
INSTANCE_COMPARTMENT_OCID="${INSTANCE_COMPARTMENT_OCID:-$(jq -r '.compartmentId // empty' <<<"$metadata")}"
COMPARTMENT_OCID="${COMPARTMENT_OCID:-$INSTANCE_COMPARTMENT_OCID}"
[[ -n "$OCI_REGION" ]] || die "OCI_REGION could not be determined."
[[ -n "$COMPARTMENT_OCID" ]] || die "Compartment OCID could not be determined. Pass --compartment-id."

oci_cmd() {
  local command=(oci "$@")
  [[ -z "$OCI_AUTH_MODE" ]] || command+=(--auth "$OCI_AUTH_MODE")
  command+=(--region "$OCI_REGION")
  is_true "$USE_REALM_SPECIFIC_ENDPOINT" && command+=(--realm-specific-endpoint)
  "${command[@]}"
}

printf 'Region:        %s\n' "$OCI_REGION"
printf 'Compartment:   %s\n' "$COMPARTMENT_OCID"
printf 'Topic name:    %s\n' "$TOPIC_NAME"
printf 'Addresses:     %s\n' "${EMAILS[*]}"

topics_json="$(oci_cmd ons topic list --compartment-id "$COMPARTMENT_OCID" --all 2>/dev/null || printf '{"data":[]}')"
topic_ocid="$(jq -r --arg n "$TOPIC_NAME" '[.data[]? | select(.name == $n and ((."lifecycle-state" // "ACTIVE") != "DELETING")) | ."topic-id"] | first // empty' <<<"$topics_json")"

if [[ -n "$topic_ocid" ]]; then
  printf 'Existing topic: %s (will be reused)\n' "$topic_ocid"
else
  printf 'Existing topic: none found, a new one will be created\n'
fi

if ! is_true "$EXECUTE"; then
  printf '\nDRY RUN ONLY. Re-run with --execute to create the topic and subscriptions.\n'
  exit 0
fi

if [[ -z "$topic_ocid" ]]; then
  printf '\nCreating topic...\n'
  response="$(oci_cmd ons topic create \
    --name "$TOPIC_NAME" \
    --compartment-id "$COMPARTMENT_OCID" \
    --description "Success and failure alerts for CD3 instance backups")"
  topic_ocid="$(jq -r '.data."topic-id" // .data.id // empty' <<<"$response")"
  [[ -n "$topic_ocid" ]] || die "OCI did not return a topic OCID."
  printf 'Topic created: %s\n' "$topic_ocid"
fi

subs_json="$(oci_cmd ons subscription list --compartment-id "$COMPARTMENT_OCID" --topic-id "$topic_ocid" --all 2>/dev/null || printf '{"data":[]}')"
created=0
for address in "${EMAILS[@]}"; do
  if jq -e --arg e "$address" '.data[]? | select((.endpoint // "") == $e)' <<<"$subs_json" >/dev/null; then
    printf 'Already subscribed, skipping: %s\n' "$address"
    continue
  fi
  sub_response="$(oci_cmd ons subscription create \
    --compartment-id "$COMPARTMENT_OCID" \
    --topic-id "$topic_ocid" \
    --protocol EMAIL \
    --subscription-endpoint "$address")"
  state="$(jq -r '.data."lifecycle-state" // "PENDING"' <<<"$sub_response")"
  printf 'Subscribed %s (state: %s)\n' "$address" "$state"
  created=$((created + 1))
done

printf '\nDone. Add this line to %s:\n\n' "$CONFIG_FILE"
printf 'ONS_TOPIC_OCID="%s"\n\n' "$topic_ocid"
if (( created > 0 )); then
  printf 'IMPORTANT: %s new subscription(s) are PENDING. OCI has emailed each address a\n' "$created"
  printf 'confirmation link, valid for three days. Nothing is delivered to an address\n'
  printf 'until someone clicks it.\n\n'
fi
printf 'Then prove delivery end to end:\n'
printf '  backup_cd3_instance.sh --config %s --test-notification\n' "$CONFIG_FILE"
