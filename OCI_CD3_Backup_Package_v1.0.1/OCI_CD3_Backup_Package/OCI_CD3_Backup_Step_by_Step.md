# OCI CD3 Instance Backup — Step-by-Step Implementation Guide

**Version 1.0.1.** See "Changes since 1.0.0" at the end of this document.

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
| `cd3-backup.service` | systemd backup service |
| `cd3-backup.timer` | Daily systemd schedule |

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
