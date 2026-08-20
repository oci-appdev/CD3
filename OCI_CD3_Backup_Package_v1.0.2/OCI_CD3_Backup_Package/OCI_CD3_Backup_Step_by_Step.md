# OCI CD3 Instance Backup — Step-by-Step Implementation Guide

**Version 1.0.2.** See "Changes since 1.0.0" at the end of this document.

This package backs up the complete CD3 compute instance and the CD3 deployment artifacts required for recovery. It is designed for a private-first OCI/SCCA environment and supports OCI Government regions through realm-specific endpoints.

## What the backup contains

| Backup layer | Protected content | Recovery use |
|---|---|---|
| OCI volume backup | Boot volume and every attached block volume | Rebuild the CD3 server |
| Logical CD3 archive | CD3 workbooks, scripts, generated Terraform, local state and logs | Recover configuration without rebuilding the VM |
| Resource Manager export | Stack configuration ZIP, state and job inventory | Preserve OCI-managed Terraform state |
| OCI inventory | Instance, volumes, VNICs, subnets, shape, tags and attachments | Reconstruct the instance accurately |

The scripts do not delete the original instance, volumes, Resource Manager stacks, or backup objects.

## Files in this package

| File | Purpose |
|---|---|
| `backup_cd3_instance.sh` | Main backup script |
| `setup_cd3_volume_group.sh` | Discovers volumes and creates the coordinated volume group |
| `verify_cd3_backup.sh` | Downloads and validates the archive and OCI backup status |
| `restore_cd3_artifacts.sh` | Safely restores logical files into a new staging directory |
| `cd3-backup.conf.example` | Configuration template |
| `iam-policy-template.txt` | Dynamic group and IAM policy template |
| `setup_cd3_notifications.sh` | Creates the alert topic and email subscriptions |
| `cd3-backup-notify.sh` | Standalone notifier, and the systemd failure backstop |
| `cd3-backup.service` | systemd backup service |
| `cd3-backup.timer` | Daily systemd schedule |
| `cd3-backup-failure.service` | Sends email when the backup unit fails outright |

## Step 1 — Record the OCI information

Collect these values before starting:

- CD3 instance OCID.
- CD3 instance compartment name.
- Network compartment name.
- OCI region used by the CD3 instance.
- Object Storage backup compartment name.
- Resource Manager stack OCIDs and their compartment name.
- Optional OCI Notifications topic OCID.

The main script discovers the instance OCID, compartment, region and availability domain from OCI IMDSv2 when it runs on the CD3 instance. Do not hard-code `us-ashburn-1` or `us-langley-1` unless that is the confirmed target region.

## Step 2 — Create the operational backup bucket

In the OCI Console:

1. Open **Storage** → **Object Storage & Archive Storage** → **Buckets**.
2. Select the backup compartment.
3. Create a private bucket named `cd3-operational-backups`.
4. Use the Standard storage tier initially.
5. Keep public access disabled.
6. Use Oracle-managed encryption or the approved Vault key.
7. Do not configure a locked retention rule on this operational bucket.

Keep the operational bucket separate from the locked evidence bucket under the EBLZ logging design. Only validated evidence packages should be copied into the locked bucket.

## Step 3 — Create the dynamic group

IAM groups, dynamic groups and policies are home-region resources.

1. Open **Identity & Security** → **Dynamic Groups**.
2. Create `CD3-Backup-Instances`.
3. Use the exact-instance rule from `iam-policy-template.txt`:

```text
ALL {instance.id = '<CD3_INSTANCE_OCID>'}
```

Exact-instance matching prevents another compute instance in the compartment from inheriting backup permissions.

## Step 4 — Create the IAM policy

1. Open **Identity & Security** → **Policies**.
2. Select the appropriate parent compartment or tenancy policy location.
3. Create a policy named `CD3-Instance-Backup-Policy`.
4. Copy the statements from `iam-policy-template.txt`.
5. Replace every placeholder.
6. Validate the policy before continuing.

Do not add defined tags to the configuration until the tag namespace and keys exist in the tenancy. The default configuration uses free-form tags to avoid an OCI `400 Invalid tags` failure.

## Step 5 — Check the operating-system prerequisites

Connect to the CD3 instance and run:

```bash
oci --version
jq --version
curl --version
tar --version
flock --version
```

The required commands are:

- OCI CLI.
- `jq`.
- `curl`.
- GNU `tar` and `gzip`.
- `sha256sum`.
- `flock`, normally provided by `util-linux`.

If a package is missing on Oracle Linux or RHEL, install it through the approved repository. Follow Oracle's current OCI CLI installation documentation rather than placing an unsigned CLI binary on the server.

## Step 6 — Install the package on the CD3 instance

Assuming the package files are in the current directory:

```bash
sudo mkdir -p /opt/cd3-backup /etc/cd3-backup /var/lib/cd3-backup

sudo install -m 0750 backup_cd3_instance.sh /opt/cd3-backup/
sudo install -m 0750 setup_cd3_volume_group.sh /opt/cd3-backup/
sudo install -m 0750 verify_cd3_backup.sh /opt/cd3-backup/
sudo install -m 0750 restore_cd3_artifacts.sh /opt/cd3-backup/
sudo install -m 0750 setup_cd3_notifications.sh /opt/cd3-backup/
sudo install -m 0750 cd3-backup-notify.sh /opt/cd3-backup/
sudo install -m 0644 OCI_CD3_Backup_Step_by_Step.md /opt/cd3-backup/

sudo install -m 0640 cd3-backup.conf.example /etc/cd3-backup/cd3-backup.conf
sudo chown -R opc:opc /opt/cd3-backup /var/lib/cd3-backup
sudo chmod 0700 /var/lib/cd3-backup
sudo chown root:opc /etc/cd3-backup/cd3-backup.conf
```

If the CD3 service account is not `opc`, substitute the correct Linux user and group. The same user must be set in `cd3-backup.service`.

## Step 7 — Configure the backup

Edit the configuration:

```bash
sudo vi /etc/cd3-backup/cd3-backup.conf
```

At minimum, update:

```bash
BACKUP_BUCKET="cd3-operational-backups"

CD3_PATHS=(
  "/replace/with/the/real/cd3/path"
  "/replace/with/the/workbook/path"
)

ORM_STACK_OCIDS=(
  "ocid1.ormstack..."
)
```

Important configuration rules:

- Every CD3 path must be a specific absolute path.
- Do not enter `/` as a CD3 path.
- Include the original workbooks, generated Terraform, state, plans and deployment logs.
- Terraform state and `tfvars` may contain sensitive values. Keep the bucket private and encrypted.
- The scripts exclude `.oci`, `.ssh`, PEM files and common private-key filenames.
- Leave `DEFINED_TAGS_JSON` empty until the tags have been validated.

## Step 8 — Test instance-principal access

Run the authentication test as the same Linux user that will run the service:

```bash
sudo -u opc oci os ns get \
  --auth instance_principal \
  --realm-specific-endpoint
```

Then test access to the backup bucket:

```bash
sudo -u opc oci os bucket get \
  --bucket-name cd3-operational-backups \
  --auth instance_principal \
  --realm-specific-endpoint
```

If either command returns `NotAuthorizedOrNotFound`, correct the dynamic-group rule, policy scope or bucket name before proceeding.

## Step 9 — Create the volume group

First run discovery only:

```bash
sudo -u opc /opt/cd3-backup/setup_cd3_volume_group.sh \
  --config /etc/cd3-backup/cd3-backup.conf
```

Review the instance OCID, availability domain and discovered volume count. Then create the group:

```bash
sudo -u opc /opt/cd3-backup/setup_cd3_volume_group.sh \
  --config /etc/cd3-backup/cd3-backup.conf \
  --execute
```

The script prints a line like:

```bash
VOLUME_GROUP_OCID="ocid1.volumegroup..."
```

Copy that line into `/etc/cd3-backup/cd3-backup.conf`.

The main backup script validates that the volume group contains the boot volume and every currently attached block volume. If a new volume is attached later, the backup stops until the volume group is updated.

## Step 9b — Set up email alerting

Backups that fail quietly are the ones that hurt. Configure this before the
first scheduled run, not after.

### Create the topic and subscribe your recipients

```bash
sudo -u opc /opt/cd3-backup/setup_cd3_notifications.sh \
  --config /etc/cd3-backup/cd3-backup.conf \
  --email cloudops@example.gov \
  --email dl-cd3-alerts@example.gov
```

That is discovery only. Review the plan, then add `--execute`. The script reuses
an existing topic of the same name and skips addresses already subscribed, so it
is safe to re-run.

Prefer a distribution list over a personal address. A backup alert that goes to
one person on leave is not alerting.

If your security team would rather the backup instance had no power to change
who gets alerted, create the topic and subscriptions in the Console instead and
grant only `use ons-topics` in the IAM policy. The template covers both.

### Confirm the subscriptions

**Every new email subscription is `PENDING` and receives nothing until the
recipient clicks the confirmation link OCI emails them.** The link is valid for
three days. This is the single most common reason CD3 backup alerting appears to
be configured but silently delivers nothing.

Check the state of each one:

```bash
oci ons subscription list \
  --compartment-id <COMPARTMENT_OCID> \
  --topic-id <TOPIC_OCID> \
  --auth instance_principal --realm-specific-endpoint \
  --query 'data[*].{endpoint:endpoint,state:"lifecycle-state"}' --output table
```

### Record the topic and set your preferences

Put the topic OCID the setup script printed into the configuration:

```bash
ONS_TOPIC_OCID="ocid1.onstopic..."
NOTIFY_ON_SUCCESS=true
NOTIFY_ON_FAILURE=true
NOTIFY_ON_VERIFY=true
NOTIFY_ENVIRONMENT="PROD-SCCA"
NOTIFY_SUBJECT_PREFIX="[CD3 Backup]"
```

Subject lines come out as
`[CD3 Backup] PROD-SCCA SUCCESS - cd3-host-01 - scheduled` or
`[CD3 Backup] PROD-SCCA FAILED - cd3-host-01 - Creating coordinated OCI volume-group backup.`,
so the failing stage is visible on a phone without opening the mail.

### Prove it end to end

```bash
sudo -u opc /opt/cd3-backup/backup_cd3_instance.sh \
  --config /etc/cd3-backup/cd3-backup.conf \
  --test-notification
```

This publishes a test message and exits without touching any backup. Do not move
on until the mail actually arrives in the recipients' inboxes. Delivery is the
thing being tested here, not configuration syntax.

### What gets emailed

| Event | Email | Controlled by |
|---|---|---|
| Backup succeeded | Backup ID, volume backup OCIDs, Object Storage path, duration, and the exact command to verify it | `NOTIFY_ON_SUCCESS` |
| Backup failed for any reason | Failing stage, the specific error, exit code, retained diagnostics path, and the `journalctl` command to investigate | `NOTIFY_ON_FAILURE` |
| A safety guard refused to run | Same as failure, quoting which guard fired | `NOTIFY_ON_FAILURE` |
| Backup killed on timeout or reboot | Failure email from the signal handler, plus a second from the systemd `OnFailure` unit | `NOTIFY_ON_FAILURE` |
| Backup unit failed to start at all | Failure email from `cd3-backup-failure.service` | always, if the topic is set |
| Verification passed or failed | Result, backup ID, and the reason on failure | `NOTIFY_ON_VERIFY` |
| Dry run | Nothing, unless `NOTIFY_ON_DRY_RUN=true` | `NOTIFY_ON_DRY_RUN` |

A failure to publish is never swallowed. If the topic OCID is wrong or the
policy is missing, the run logs `NOTIFICATION FAILED` at ERROR level and names
the ONS response, because alerting that appears to work but does not is worse
than none at all. Setting `REQUIRE_NOTIFICATION_TOPIC=true` goes further and
refuses to take a backup nobody would be told about.

### What this cannot tell you

Alerting is driven by runs that happen. If the host is down, the timer is
disabled, or someone masks the unit, there is nothing to send an email and the
inbox simply stays quiet. Silence is not success.

Cover that gap with one of:

- Leave `NOTIFY_ON_SUCCESS=true` and treat a missing daily success mail as an
  incident. Simple, and it uses what you already have.
- An OCI Monitoring alarm on the volume backup count in the compartment, firing
  when no new backup appears in 26 hours.
- `systemctl list-timers cd3-backup.timer` in an existing daily health check.

The first option is why success email defaults to on. Turn it off only once you
have one of the others.

## Step 10 — Run the safe dry run

```bash
sudo -u opc /opt/cd3-backup/backup_cd3_instance.sh \
  --config /etc/cd3-backup/cd3-backup.conf \
  --dry-run
```

The dry run verifies:

- OCI authentication.
- Backup bucket access.
- Instance and volume discovery.
- CD3 paths.
- Resource Manager stack access.
- Absence of active Terraform/CD3 changes.
- Volume-group membership.
- The retention-period shape this OCI CLI expects (printed for comparison).

It does not create a volume backup, export Resource Manager state, or upload an object.

If the dry run reports that the retention value it will send and the shape your
CLI expects disagree, set `RETENTION_PERIOD_JSON` in the configuration to match
your CLI before running a real backup.

## Step 11 — Create the first full backup

```bash
sudo -u opc /opt/cd3-backup/backup_cd3_instance.sh \
  --config /etc/cd3-backup/cd3-backup.conf \
  --mode full \
  --backup-type FULL
```

Expected completion output includes:

- `CD3 backup completed successfully`.
- A unique backup ID.
- An OCI volume-group backup OCID.
- The Object Storage directory.

The default backup retention is 30 days, sent to OCI as the `retentionPeriod`
of the volume-group or block-volume backup. Boot-volume backups are a special
case: `oci bv boot-volume-backup create` does not accept `--retention-period`,
so the script creates the backup first and then applies retention with
`oci bv boot-volume-backup update`. If that update fails the script warns and
continues — the backup exists, but you must expire it yourself. This is one more
reason to use the volume-group path from Step 9.

Subsequent scheduled backups use the configured `INCREMENTAL` type.

The volume backup is **crash-consistent**, not application-consistent. The
script calls `sync` before the snapshot but does not freeze the filesystem or
quiesce applications. Combined with the Step 14 guard against running during an
active Terraform or CD3 apply, this is appropriate for CD3; do not describe it
to reviewers as an application-quiesced backup.

## Step 12 — Verify the backup

Verify the newest backup:

```bash
sudo -u opc /opt/cd3-backup/verify_cd3_backup.sh \
  --config /etc/cd3-backup/cd3-backup.conf
```

Verify a particular backup:

```bash
sudo -u opc /opt/cd3-backup/verify_cd3_backup.sh \
  --config /etc/cd3-backup/cd3-backup.conf \
  --backup-id 20260820T120000Z-example
```

The verification script:

1. Selects the backup by its manifest, so volume-only backups are verifiable too.
2. Refuses to continue if the manifest is missing or does not parse.
3. Downloads the archive and checksum and verifies SHA-256 integrity.
4. Confirms required inventory files exist inside the archive.
5. Confirms every OCI volume backup in the manifest remains `AVAILABLE`, and
   prints how many records it checked.
6. Fails if a full or volume-only backup carries no OCI backup records at all.

The script fails closed. It exits non-zero unless it positively confirmed every
check it reports, and the final line states the number of checks performed. A
run that ends in anything other than `Backup verification PASSED (N checks).`
should be treated as a failed backup.

## Step 13 — Schedule the daily backup

Review `cd3-backup.service` and change `User=` and `Group=` if CD3 does not run as `opc`.

Install the service and timer:

```bash
sudo install -m 0644 cd3-backup.service /etc/systemd/system/
sudo install -m 0644 cd3-backup.timer /etc/systemd/system/
sudo install -m 0644 cd3-backup-failure.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cd3-backup.timer
```

Confirm the schedule:

```bash
systemctl list-timers cd3-backup.timer
```

The supplied timer runs daily at 02:15 UTC with a randomized delay of up to 15 minutes.

Run an immediate scheduled-service test:

```bash
sudo systemctl start cd3-backup.service
sudo journalctl -u cd3-backup.service -n 100 --no-pager
```

`cd3-backup.service` declares `OnFailure=cd3-backup-failure.service`. That unit
is the backstop for failures the backup script cannot report itself — killed on
`TimeoutStartSec`, out of memory, host rebooted mid-run, or the script missing
entirely. In those cases you may receive two emails, one from the script and one
from systemd. That is deliberate: a duplicate is cheap, silence is not.

Confirm the backstop works:

```bash
sudo systemctl start cd3-backup-failure.service
sudo journalctl -u cd3-backup-failure.service -n 20 --no-pager
```

## Step 14 — Take a pre-change backup

Before every CD3 or Terraform apply:

```bash
sudo -u opc /opt/cd3-backup/backup_cd3_instance.sh \
  --config /etc/cd3-backup/cd3-backup.conf \
  --mode full \
  --backup-type FULL \
  --retention-days 90 \
  --pre-change CHG-REPLACE-ME
```

The script stops if it detects an active Terraform apply, destroy, import, CD3 apply or Resource Manager job.

## Step 15 — Restore logical CD3 files safely

Always restore into a new staging directory. First preview the action:

```bash
sudo -u opc /opt/cd3-backup/restore_cd3_artifacts.sh \
  --config /etc/cd3-backup/cd3-backup.conf \
  --target-dir /var/tmp/cd3-restore-test
```

Then perform the verified extraction:

```bash
sudo -u opc /opt/cd3-backup/restore_cd3_artifacts.sh \
  --config /etc/cd3-backup/cd3-backup.conf \
  --target-dir /var/tmp/cd3-restore-test \
  --execute
```

The restore script refuses broad system directories and refuses a non-empty target. It does not copy files into the active CD3 installation.

## Step 16 — Restore the complete instance

Perform full recovery in the isolated Sandbox compartment:

1. Open **Storage** → **Block Storage** → **Volume Group Backups**.
2. Select the backup OCID recorded in `backup-manifest.json`.
3. Restore the volume group.
4. Identify the restored boot volume and data volumes.
5. Create a new compute instance from the restored boot volume.
6. Use an isolated Sandbox subnet and security groups.
7. Do not reuse the production private IP automatically.
8. Attach the restored data volumes in the original order.
9. Verify mounts, CD3, OCI CLI and Terraform.
10. Run an inventory comparison or Terraform plan only. Do not run `terraform apply` from the recovery instance.
11. Record the recovery time and validation evidence.
12. Remove the recovery resources only after approval.

Never operate the original and restored Terraform state against the same production resources simultaneously.

## Step 17 — Configure operational Object Storage lifecycle

The volume-backup retention period is sent directly to OCI by the script (see
the note in Step 11 about boot-volume backups). Confirm on your first real
backup that the retention actually landed — `verify_cd3_backup.sh` now prints
each backup's expiry time. Configure Object Storage lifecycle separately:

- Scheduled backup prefix: retain 30 days.
- Pre-change backup prefix: retain 90 days.
- Monthly validated recovery package: retain according to the approved policy.
- Locked evidence copies: use the separate EBLZ logging/evidence bucket.

Do not lock a retention rule until the design has been validated through at least one complete restore test. OCI retention-rule locking is irreversible.

## Step 18 — Quarterly recovery test

Each quarter:

1. Select a backup without changing production.
2. Verify the logical archive.
3. Restore the OCI volume group into Sandbox.
4. Launch an isolated recovery instance.
5. Confirm CD3 workbooks, Terraform state and generated files.
6. Confirm the instance can read OCI but cannot modify production.
7. Record the RPO and RTO achieved.
8. Save the recovery evidence under the approved retention policy.

## Troubleshooting

| Error | Likely cause | Corrective action |
|---|---|---|
| `NotAuthorizedOrNotFound` | Dynamic group has not propagated, policy scope is wrong, or resource name is wrong | Verify the exact instance OCID, compartments and bucket name; allow several minutes for IAM propagation |
| `Invalid tags` | Defined-tag namespace/key is absent or the instance principal cannot use it | Leave `DEFINED_TAGS_JSON` empty until the tags are validated |
| Multiple volumes but no group | The boot and data volumes are not protected as one recovery point | Run `setup_cd3_volume_group.sh` and add the returned OCID |
| Active Terraform/CD3 process | Deployment is running | Wait for it to finish; do not bypass the safety check |
| Terraform lock file detected | State is locked or a prior operation did not exit cleanly | Investigate the lock owner; never delete the lock blindly |
| Backup wait timeout | Large volume or OCI service delay | Check the backup in OCI; increase `BACKUP_WAIT_SECONDS` only after confirming it is progressing |
| No CD3 paths found | Example paths were not replaced | Correct `CD3_PATHS` in the configuration |
| Checksum failure | Upload/download corruption or wrong object selection | Do not restore; preserve logs and create a new backup |
| `no such option: --retention-period` | An OCI CLI older than the one this package targets, on a command that gained the option later | Set `APPLY_RETENTION_PERIOD=false` and manage expiry through Object Storage lifecycle and manual review |
| Verify prints an expiry of `none` | The retention period was accepted but not applied | Run the dry run and compare the two retention lines it prints; set `RETENTION_PERIOD_JSON` to match your CLI |
| Manifest is missing or corrupt | Interrupted upload | Treat the backup as unusable and take a new one; do not restore from it |
| Configured alerting but no email arrives | The email subscription is still `PENDING` | Have the recipient click the confirmation link OCI sent; check with `oci ons subscription list`; re-send with `oci ons subscription resend-confirmation` |
| `NOTIFICATION FAILED` in the journal | Wrong `ONS_TOPIC_OCID`, or the dynamic group lacks `use ons-topics` | Compare the OCID against the Console; confirm the policy is in the topic's compartment |
| Backup succeeds but no success mail | `NOTIFY_ON_SUCCESS=false` | Set it to true, or rely on one of the missed-run checks in Step 9b |
| No mail at all and no journal entries | The run never started | Check `systemctl list-timers cd3-backup.timer` and whether the host was up; this is the gap Step 9b warns about |
| Two failure emails for one run | The script reported, and the systemd `OnFailure` unit reported too | Expected for timeout or reboot kills |
| Two backups ran at once | `WORK_ROOT`/`LOCK_FILE` were left under `/var/tmp` while the unit sets `PrivateTmp=true` | Confirm both point at `/var/lib/cd3-backup` |

## Oracle references

- [OCI instance-principal authentication](https://docs.oracle.com/en-us/iaas/Content/Identity/callresources/Configuring_the_SDK_CLI_or_Terraform.htm)
- [OCI volume groups](https://docs.oracle.com/en-us/iaas/Content/Block/Concepts/volumegroups.htm)
- [OCI volume-group backup CLI](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/bv/volume-group-backup/create.html)
- [OCI Resource Manager stack state export](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Tasks/get-stack-tf-state.htm)
- [OCI Resource Manager stack configuration export](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Tasks/get-stack-tf-config.htm)
- [OCI Object Storage upload and checksum verification](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/os/object/put.html)
- [OCI Object Storage retention rules](https://docs.oracle.com/en-us/iaas/Content/Object/Tasks/usingretentionrules.htm)
- [OCI Core Services policy reference](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/corepolicyreference.htm)
- [OCI Resource Manager policy reference](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/resourcemanagerpolicyreference.htm)

## Changes since 1.0.0

Fixes applied after a full audit of 1.0.0. The first two were release-blocking.

| # | Severity | Change |
|---|---|---|
| 1 | Blocker | `oci bv boot-volume-backup create` does not accept `--retention-period`, but 1.0.0 passed one shared argument list to all three create commands. Every backup on the no-volume-group path — the shipped default — failed with `Error: no such option: --retention-period`. The argument lists are now separate, and boot-volume retention is applied afterwards via `bv boot-volume-backup update`. |
| 2 | Blocker | The retention JSON used `timeAmount`/`timeUnit`. Oracle documents `retentionTimeAmount`/`retentionTimeUnit`, so retention was silently not applied and backups would never expire. Corrected, made overridable through `RETENTION_PERIOD_JSON`, and the dry run now prints both the value it sends and the shape the local CLI expects. |
| 3 | High | `verify_cd3_backup.sh` printed `Backup verification PASSED` and exited 0 on a corrupt manifest, because a `jq` failure inside `mapfile < <(...)` is invisible to `set -e`. Replaced with a helper that fails closed; the manifest is validated before use; the script now asserts a non-zero record count and reports how many checks it ran. |
| 4 | High | Verification passed vacuously when a manifest carried no volume backup records. A full or volume-only backup with zero records is now an error. |
| 5 | Medium | `WORK_ROOT` and `LOCK_FILE` defaulted to `/var/tmp/cd3-backup` while the service unit set `PrivateTmp=true`, giving the unit a private `/var/tmp`. The `flock` guard therefore did not prevent a scheduled run and a manual pre-change run from executing simultaneously, and the retained-diagnostics path was destroyed on unit exit. Moved to `/var/lib/cd3-backup`, with `StateDirectory=cd3-backup` in the unit. |
| 6 | Medium | Volume-only backups uploaded nothing, so their backup OCIDs survived only in the run log and could never be verified. The manifest is now always uploaded when a bucket is configured, and verification selects backups by manifest rather than by archive. |
| 7 | Low | `--dry-run` downloaded the Resource Manager config ZIP and `terraform.tfstate` before the dry-run gate. Stack access and active-job checks still run during a dry run; the state export now happens only in a real backup. |
| 8 | Low | Attachment filters matched any state other than `DETACHED`, which included volumes in `DETACHING`. They now match `ATTACHED` only. |
| 9 | Low | The log line claimed it was creating an "encrypted-at-rest" archive. The archive is plaintext on local disk and encrypted only once Object Storage receives it; the wording now says so. |
| 10 | Low | `restore_cd3_artifacts.sh` checked member paths for `/` and `..` but not link targets. A symlink pointing outside the staging directory is now rejected. |
| 11 | Low | Array expansions were unsafe under `set -u` on bash 4.2 (Oracle Linux 7). All expansions now use the `${arr[@]+...}` form. |

Unchanged and re-confirmed: instance-principal authentication, realm-specific
endpoints for Government regions, coordinated volume-group backups, SHA-256
upload and restore verification, the Terraform/CD3 active-operation guards, the
staging-only restore behaviour, and the absence of any delete or terminate call.

## Changes since 1.0.1

Email alerting through OCI Notifications, which 1.0.1 only partially had.

| # | Severity | Change |
|---|---|---|
| 1 | High | **Failures were mostly silent.** `notify` was only reached by the `ERR` trap, and `die` calls `exit` directly, which never triggers `ERR`. Every safety-guard refusal — active Terraform apply, state lock detected, another backup already running, no CD3 paths, volume group missing — completed with no email whatsoever. Reporting now runs from an `EXIT` trap, so every exit path notifies. |
| 2 | High | Added `TERM`/`INT` handling, so a backup killed by `TimeoutStartSec`, a reboot, or an operator sends a failure email instead of vanishing. |
| 3 | High | Added `cd3-backup-failure.service` wired to `OnFailure=`, covering failures the script cannot report itself (OOM, `SIGKILL`, script missing). |
| 4 | Medium | A failed publish was swallowed by `>/dev/null 2>&1 \|\| true`. It is now logged at ERROR level with the ONS response, and `REQUIRE_NOTIFICATION_TOPIC=true` will refuse to run a backup nobody would be told about. |
| 5 | Medium | The topic OCID is validated with `ons topic get` at startup, so a wrong OCID fails loudly on the first run rather than at the first real incident. |
| 6 | Medium | Email bodies now carry the failing stage, the specific error, exit code, backup ID, volume backup OCIDs, Object Storage path, duration, and the exact commands to verify or investigate. 1.0.0 sent a single semicolon-separated line. |
| 7 | Medium | Added `--test-notification`, which proves delivery without running a backup. |
| 8 | Medium | Added `setup_cd3_notifications.sh` to create the topic and email subscriptions idempotently, and to state plainly that new subscriptions are `PENDING` until confirmed. |
| 9 | Medium | `verify_cd3_backup.sh` now reports its result to the same topic. A backup that has quietly gone bad is worth an email. |
| 10 | Low | Subject lines carry an environment tag and the failing stage, so triage is possible from a phone notification. |
| 11 | Low | The IAM template promotes the Notifications policy from optional to required, explains that `use ons-topics` grants `ONS_TOPIC_PUBLISH`, and offers the narrower Console-managed alternative. |

Known limitation, documented in Step 9b: alerting reports on runs that happen.
A backup that never starts sends nothing, so either keep success email on and
treat its absence as an incident, or add an independent missed-run check.
