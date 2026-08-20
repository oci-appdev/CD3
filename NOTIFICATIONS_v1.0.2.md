# v1.0.2 — Email alerting

## What was wrong in 1.0.1

The package already had an `ONS_TOPIC_OCID` setting and a `notify()` function, so it looked like alerting was in place. It mostly was not.

`notify()` was only reached from the `ERR` trap. `die()` — which is how the script reports every guard refusal and validation failure — calls `exit` directly, and **`exit` does not trigger an `ERR` trap.** Reproduced against the stub CLI:

| Failure | Emails sent in 1.0.1 |
|---|---|
| Terraform state lock detected | **0** |
| Active `terraform apply` detected | **0** |
| Another backup already running | **0** |
| Multiple volumes but no volume group | **0** |
| None of the configured CD3 paths exist | **0** |
| Config file group/world-writable | **0** |
| Killed on `TimeoutStartSec` / reboot | **0** |
| OCI API error mid-run | 1 |
| Success | 1 |

So the alerting covered the case where OCI itself errored, and almost nothing else. Worse, the publish call ended in `>/dev/null 2>&1 || true` — a wrong topic OCID or missing IAM policy produced no output at all, which reads exactly like working alerting.

## What 1.0.2 does

Reporting moved from the `ERR` trap to an `EXIT` trap, so every exit path notifies. `TERM`/`INT` handlers cover kills. A systemd `OnFailure=` unit covers the cases the script cannot report on at all.

| Event | Email |
|---|---|
| Success | Backup ID, volume backup OCIDs, Object Storage path, duration, and the exact verify command |
| Any failure, including every guard refusal | Failing stage, specific error, exit code, retained diagnostics path, `journalctl` command |
| Killed on timeout or reboot | Failure email from the signal handler, plus one from the systemd backstop |
| Unit failed to start at all | Failure email from `cd3-backup-failure.service` |
| Verification passed or failed | Result and reason; a failure says plainly not to restore from that backup |
| Dry run | Silent, unless `NOTIFY_ON_DRY_RUN=true` |

Sample failure subject and body, captured from a test run:

```
SUBJECT: [CD3 Backup] PROD-SCCA FAILED - cd3-host-01 - Checking for active CD3 or Terraform changes.

CD3 backup FAILED

Environment:    PROD-SCCA
Host:           cd3-host-01
Instance:       CD3 Host 01
Region:         us-langley-1
Mode:           full
Backup ID:      20260820T152523Z-690cd051
Duration:       0 min 0 sec

Exit code:      1
Failed during:  Checking for active CD3 or Terraform changes.
Reason:         Terraform state lock detected: /home/opc/cd3_automation_toolkit/.terraform.tfstate.lock.info

NO BACKUP WAS COMPLETED FOR THIS RUN.

Investigate with:
  sudo journalctl -u cd3-backup.service -n 200 --no-pager
```

## Failures of the alerting itself are now loud

- A failed publish logs `NOTIFICATION FAILED` at ERROR with the ONS response.
- The topic OCID is validated with `ons topic get` at startup, so a wrong OCID surfaces on the first run rather than during your first real incident.
- `REQUIRE_NOTIFICATION_TOPIC=true` refuses to take a backup nobody would be told about. Default is false.

## New files

| File | Purpose |
|---|---|
| `setup_cd3_notifications.sh` | Creates the topic and email subscriptions. Idempotent — reuses an existing topic, skips addresses already subscribed. |
| `cd3-backup-notify.sh` | Standalone notifier. Backs the systemd `OnFailure` unit and lets operators test delivery independently. |
| `cd3-backup-failure.service` | Wired to `OnFailure=` in `cd3-backup.service`. |

## Setup

```bash
# 1. create topic + subscriptions (drop --execute first to see the plan)
sudo -u opc /opt/cd3-backup/setup_cd3_notifications.sh \
  --config /etc/cd3-backup/cd3-backup.conf \
  --email dl-cd3-alerts@example.gov --execute

# 2. put the printed ONS_TOPIC_OCID into the config

# 3. have each recipient click the confirmation link OCI emails them

# 4. prove delivery, without running a backup
sudo -u opc /opt/cd3-backup/backup_cd3_instance.sh \
  --config /etc/cd3-backup/cd3-backup.conf --test-notification
```

**Step 3 is the one that gets skipped.** Every new email subscription sits in `PENDING` and receives nothing until someone clicks the link, which expires after three days. That is the most common reason CD3 alerting looks configured but delivers nothing. Step 4 is what actually proves it.

IAM: `use ons-topics` is enough — it grants `ONS_TOPIC_PUBLISH` and `GetTopic`. The template also lists the `manage` statements needed only if you want the instance itself to create the topic, and recommends against granting them.

## The gap this does not close

Alerting reports on runs that happen. If the host is down, the timer is disabled, or the unit is masked, nothing runs and nothing is sent — **silence is not success.** Step 9b of the guide covers three mitigations; the default `NOTIFY_ON_SUCCESS=true` exists so that a missing daily success mail is itself the signal. Turn it off only after adding an independent missed-run check.

## Test results

32 checks, all passing: 11 covering the new notification paths, 21 re-running the full v1.0.1 regression suite to confirm nothing regressed.

| Notification check | Result |
|---|---|
| Success email content | pass |
| Guard failure emails (was 0 emails in 1.0.1) | pass |
| Active-Terraform refusal emails | pass |
| `--test-notification` sends one mail, takes no backup | pass |
| Dry run silent by default, emails when enabled | pass |
| `SIGTERM` mid-backup produces a failure email | pass |
| Broken topic OCID logged loudly, backup still completes | pass |
| `REQUIRE_NOTIFICATION_TOPIC=true` refuses to run blind | pass |
| Publish failure logged, not swallowed | pass |
| Verify failure and success emails | pass |
| Standalone notifier and setup script, including input validation | pass |

## Sources

- [oci ons message publish](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/ons/message/publish.html) — 64 KB message limit, 10 messages/min per email endpoint
- [oci ons subscription create](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/ons/subscription/create.html) — `--subscription-endpoint`, `--protocol EMAIL`
- [Create an email subscription](https://docs.oracle.com/en-us/iaas/Content/Notification/Tasks/create-subscription-email.htm) — PENDING state, confirmation URL valid three days
- [Notifications IAM policy reference](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/notificationpolicyreference.htm) — `use ons-topics` grants `ONS_TOPIC_PUBLISH`
