# Object Storage retention through CD3

Policy templates and step-by-step configuration. Prepared 24 September 2026.
Target workflow: OCI Government Cloud, CD3 2026.1.0. No live OCI resources or
permissions are changed by this package. The files contain placeholders and
are not ready for deployment until the checks below are completed.

## What to use

| File | Purpose | Statements |
| --- | --- | ---: |
| [01-cd3-runtime.txt](policies/01-cd3-runtime.txt) | Read the namespace, discover buckets, administer unlocked retention on one bucket | 3 |
| [02-create-bucket-optional.txt](policies/02-create-bucket-optional.txt) | Create that bucket if it does not exist | 1 |
| [03-lock-approvers-optional.txt](policies/03-lock-approvers-optional.txt) | Separately approved human retention-lock authority | 3 |
| [04-compartment-discovery-optional.txt](policies/04-compartment-discovery-optional.txt) | CD3 compartment lookup if not already permitted | 1 |

Use file 01 for an existing bucket. Add file 02 only for a new bucket. Do not
automatically deploy all four files. These are **additional statements for
existing IAM policies**, not four new IAM policy objects.

An IAM policy authorizes an action. The `Buckets` sheet configures the actual
retention rule. A lifecycle policy for archiving/deleting objects is a different
feature and is not configured here.

## Important finding in the repository

The inspected baseline is
[`OCI_SCCA_CD3_Governance_Gold_Master_FIXED_v4.xlsx`](../OCI_SCCA_CD3_Governance_Gold_Master_FIXED_v4.xlsx)
at repository commit `5718e38e10ad17ffe0e55b204cd912f404a44d01`.
It is not evidence of what is currently deployed.

* `Policies!E33` gives `CD3-ORM-Dynamic-Group` `manage all-resources` in EBLZ.
  `Policies!E26` also gives it tenancy policy administration.
* The workbook uses Ashburn, `EBLZ::Logging`, and an `eblz-audit-evidence`
  bucket with 365-day retention. More recent requested settings were
  `us-langley-1`, `EBLZ::VDMS::Logging`, `eblz-security-evidence-worm`, and
  seven years. **Reconcile these with the live target before deployment.**
* Existing workbooks have deliberately not been rewritten or redeployed.

OCI grants are additive. A narrower statement, including a condition excluding
`RETENTION_RULE_LOCK`, does not cancel another grant. If that broad automation
policy is live, CD3 already has retention-lock authority. To enforce separation,
use an approved restricted executor that matches no broad dynamic group, or
review and narrow the covering grants through a separate IAM change. An executor
that can rewrite IAM policies can grant itself more access. Do not remove the
existing broad permissions blindly; other deployments may rely on them. [3]

## Step 1 — Record the actual target and executor

Complete these values locally. Do not commit populated identifiers, credentials,
Terraform state, saved plans, or production evidence to this public repository.

| Input | Required value |
| --- | --- |
| Bucket region | Actual OCI region; expected `us-langley-1` |
| IAM home region | Actual tenancy home region, which may differ from the bucket region |
| CD3 Region value | Alias accepted by the installed CD3 region mapping for each region above |
| `<LOGGING_COMPARTMENT_OCID>` | OCID of the compartment that actually owns the bucket |
| `<EVIDENCE_BUCKET_NAME>` | Exact existing or approved new bucket name |
| `<CD3_EXECUTOR_DYNAMIC_GROUP_OCID>` | Dynamic group containing the Terraform execution principal |
| `<RETENTION_LOCK_APPROVERS_GROUP_OCID>` | Existing separately approved human group in the Default domain |
| Policy destinations | Existing policy names, OCIDs, attachment compartments, and owning Terraform state |
| Retention duration | Approved period; examples below use seven years |

For an OCI Resource Manager job, authorize the stack's resource principal through
its matching dynamic group. For Terraform running locally on the CD3 VM with
instance-principal authentication, authorize that instance's dynamic group.
For API-key/session-token authentication, replace `dynamic-group id
<CD3_EXECUTOR_DYNAMIC_GROUP_OCID>` with `group id <CD3_EXECUTOR_GROUP_OCID>` for
the authenticated user's group. The CD3 generator, Terraform apply, and an
administrator submitting an ORM job can use different identities.

The repo identifies `CD3-ORM-Dynamic-Group`; verify its matching rule and effective
permissions. Do not substitute the backup VM group `CD3-Backup-Instances` unless
that is genuinely the intended executor. Preserve ADFS/YubiKey requirements for
human approval and privileged sessions.

## Step 2 — Back up and check ownership

1. Export the current statements from the destination IAM policy and save its
   OCID and attachment compartment in the restricted change record.
2. Back up the working CD3 workbook and its Terraform state securely.
3. Record the bucket's current configuration and **all** retention rules,
   including rule IDs and scheduled/active locks.
4. Use the Terraform state already owning those resources. If unmanaged, use
   CD3's export/import workflow and review generated imports before continuing.
   Never put the same bucket or IAM policy under two states.
5. Confirm the destination policy has capacity for the added statements. Given
   the reported policy-object threshold, this change should update existing
   policy objects and add zero new ones.

Suggested destinations are existing `12-EBLZ-Automation` and
`01-Global-Security` **if deployed**. The inspected repo instead names its
automation object `EBLZ-CD3-ORM-Automation`. Use the real existing object and keep
its name and attachment. The templates include tenancy-scoped namespace access,
so use an existing **root-attached** policy for the complete set.

## Step 3 — Prepare the IAM statements

1. Copy the relevant template files into a private working directory.
2. Replace each `<PLACEHOLDER>` with the confirmed value. Keep the single quotes
   around the bucket name and permission names. OCIDs following `id` are unquoted.
3. Copy only lines beginning `Allow`; comments are instructions, not statements.
4. Reuse an existing equivalent grant instead of adding a duplicate.

File 01 uses an allowlist of bucket permissions: `BUCKET_READ`, `BUCKET_UPDATE`,
and `RETENTION_RULE_MANAGE`, plus separate bucket discovery and namespace read.
It grants no object-content access, bucket deletion, pre-authenticated-request
creation, IAM administration, or lock permission. Optional file 02 adds only
`BUCKET_CREATE`. Namespace read is included because the checked CD3 Terraform
module passes `compartment_id = var.tenancy_ocid` when resolving the namespace.
[1, 4]

`BUCKET_UPDATE` is also usable for other bucket-setting changes. This is scoped
bucket administration, not a deny control for every non-retention setting.
Enforce private visibility in configuration and review the plan. Bucket-name
conditions are case-insensitive, so avoid case-only name variants. [1]
The templates do not include a region condition: the same bucket name in the
same compartment in another region would also match. Use a unique evidence
bucket name or have the IAM owner add an approved regional restriction.

## Step 4 — Append within CD3's existing `Policies` block

Open the **authoritative working workbook**, not an older file merely because
it has a higher suffix. In the `Policies` sheet:

1. Find the existing destination policy's first row and all its continuation rows.
2. Keep its `Region`, `Name`, `Compartment Name`, description, tags, and existing
   statements unchanged. Its region must map to the tenancy's home region.
3. Insert the new statements before the next policy block or `<END>`.
4. For each added continuation row, put **one complete Allow statement** into
   `Policy Statements`. Leave `Region`, `Name`, `Compartment Name`, and
   `Description` empty, following the existing continuation-row format.
5. Leave `Policy Statement Groups` and `Policy Statement Compartment` empty for
   these fully written OCID-based statements. No `$` or `compartment *`
   substitution is needed.
6. Keep the complete existing statement list. Updating a Terraform-managed policy
   with only this package's additions would remove its other statements.

An existing IAM administrator performs this bootstrap in the appropriate IAM
workflow. **Do not grant normal retention automation `manage policies` just so
it can grant itself the required permissions.**

## Step 5 — Generate, review, and apply the IAM change

From the installed CD3 toolkit directory, use your existing properties file:

```bash
python3 setUpOCI.py /absolute/path/to/approved-setUpOCI.properties
```

Confirm `cd3file`, `outdir`, `prefix`, authentication, and workflow are correct.
For generation, the workflow is `create_resources`. In CD3 2026.1.0 choose
**Identity → Add/Modify/Delete Policies**. Review generated Terraform in the
existing IAM state/work directory:

```bash
terraform fmt -check
terraform validate
terraform plan -out=retention-iam.tfplan
terraform show retention-iam.tfplan
```

Stop if the plan creates a replacement policy, removes existing statements,
destroys resources, changes unrelated privileges, or leaves placeholders.
Apply only the approved saved plan using the IAM deployment identity:

```bash
terraform apply retention-iam.tfplan
```

For Resource Manager, use its Plan and approved Apply jobs instead of these
local Terraform commands. Allow IAM changes to propagate and verify access under
the actual retention executor before proceeding.

## Step 6 — Configure the retention rule in `Buckets`

Use a disposable nonproduction bucket first. These settings describe a **new**
production evidence bucket example, not a replacement row for an existing one:

| CD3 column | Example value |
| --- | --- |
| Region | CD3 alias mapped to `us-langley-1` |
| Compartment Name | Confirmed CD3 compartment mapping, expected `EBLZ::VDMS::Logging` |
| Bucket Name | `eblz-security-evidence-worm` |
| Storage Tier | `Standard` |
| Auto Tiering | `Disabled` |
| Object Versioning | `Disabled` |
| Emit Object Events | `Enabled` if required by the approved design |
| Visibility | `Private` |
| Retention Rules | `seven-year-security-evidence::7::YEARS` |
| Replication Policy | Empty for this new-bucket example |
| Lifecycle fields | Empty for this new-bucket retention-only example |

The checked CD3 parser expects `RuleName::TimeAmount::TimeUnit` for an unlocked
time-bound rule. **Do not add a fourth component, a trailing `::`, or a lock
date.** Use `validation-retention::1::DAYS` only on the disposable test bucket.
Separate multiple rules with actual newlines inside the cell. [4]

For an existing bucket, preserve its name, compartment, encryption key, tags,
event setting, lifecycle/replication configuration, and existing retention rules.
Change only the approved retention value. A blank rule cell can generate an empty
retention list and remove an unlocked rule. Check the full resulting plan.

Do not target the CD3 Terraform-state bucket: state must remain writable.
Versioning-enabled buckets and replication destination buckets are not eligible
for this procedure. A previously versioned bucket requires separate review of
its suspended-versioning state and historical versions. Never silently change
versioning to make the deployment pass. [2]

## Step 7 — Generate and inspect the bucket plan

Use the established bucket state/work directory and the same CD3 entry command.
Choose **Storage → Add/Modify/Delete Object Storage Buckets**. Check the generated
`<prefix>_buckets.auto.tfvars` and plan for:

* Correct region, compartment and exact bucket. No replacement or destruction.
* `access_type = "NoPublicAccess"`, the approved versioning state, and no
  unintended encryption, tag, lifecycle, or replication change.
* The intended `retention_rules` entry: correct display name, amount `7`,
  unit `YEARS`, and **no scheduled lock**.
* All pre-existing retention rules preserved unless a change is explicitly approved.

CD3 2026.1.0 emits an empty string for an unspecified `time_rule_locked` in its
tfvars template. Inspect the provider plan and later API readback: the accepted
result must have no scheduled lock. If the installed provider rejects that
empty value, stop and use a reviewed template/module correction that omits it
or supplies `null`; do not invent a date to satisfy validation. Retention is a
nested block of `oci_objectstorage_bucket`, not a separate retention Terraform
resource in this workflow. [4, 5]

Run `terraform validate` and create a saved bucket plan as in step 5, then apply
only after review under the intended retention executor. In Resource Manager,
use the corresponding Plan and approved Apply jobs. Do not run `terraform destroy`.

## Step 8 — Verify in nonproduction, then production

| Check | Expected result |
| --- | --- |
| Read bucket and list/get retention rules as the executor | Success on the target bucket |
| Create/update an unlocked rule | Success on the approved test target |
| Readback | Approved duration; no scheduled lock |
| New uniquely named object from the approved writer | Success |
| Overwrite/delete a still-protected test object | Retention rejection, using a test identity that otherwise has the needed object permission |
| Runtime identity attempts to lock a test rule | Authorization failure, after effective grants have been reviewed |
| Runtime identity accesses a different bucket or manages IAM | Denied unless explicitly covered by another reviewed grant |
| Second Terraform plan after apply | No unintended changes |

A denied object delete by the runtime identity alone proves nothing about
retention: this package does not grant it object deletion. Test only disposable
objects; never attempt destructive validation on production evidence.

A lock-negative test must run **only in a disposable environment**. If it
unexpectedly succeeds, stop, record the excessive access, and have an authorized
approver cancel the test lock schedule during the grace period. Do not allow a
test schedule to become permanent.

Record job IDs, policy diffs, plan review, retention readback, test evidence, and
approvals in the restricted change record. Live IAM and CD3/provider verification
must occur in your environment; local package checks are not proof of deployment.

## Step 9 — Handle locking as a separate approved change

The initial rule is deliberately unlocked. If permanent locking is required,
the approved human group can receive file 03. For locking through a CD3-generated
configuration, the **actual applying identity** must be the approved group member
or a separately authorized dedicated lock executor. A human's permissions do
not transfer to an ORM stack merely because that human starts the job.

Only in that separate change add the fourth field:

```text
seven-year-security-evidence::7::YEARS::<APPROVED_RFC3339_UTC_LOCK_TIME>
```

Use a future UTC timestamp at least 14 days after the lock-scheduling request,
with an operational buffer. Obtain records-management/security approval and
arrange review before the delay expires. Once effective, a lock cannot be
reversed or its duration shortened. [2]

Keep the approved lock state in the same bucket source of truth and Terraform
state. Do not later remove the fourth field or let a normal pipeline revert it.
Refresh/readback and plan review are mandatory after a separately executed lock
change. An immutable rule's required future change may need the privileged
maintenance workflow.

## Step 10 — Know the boundaries and rollback limits

* Before locking, an authorized change can restore the prior unlocked rule and
  policy configuration. Do not delete production evidence as a rollback method.
* Reverting Git does not undo a cloud apply. Reverting IAM does not undo retention.
  After a lock takes effect, code rollback cannot remove that commitment.
* Customer-managed encryption needs the established Vault key/service grants.
  Preserve them; this package does not grant Vault administration.
* Defined tags and Terraform-state access need their existing approved permissions.
  These templates are a retention supplement, not a full CD3 bootstrap policy.
* Archive lifecycle, Connector Hub log delivery, object readers/writers, and
  cross-tenancy evidence access require separate permission/configuration reviews.
  Do not add broad `manage objects` just to fix a retention-only authorization error.

## Local checks

From this directory:

```bash
python3 -m unittest discover -s tests -v
```

The checks inspect templates, scope, placeholders, and the separation of lock
permission. They make no OCI calls. An optional contract check exercises the
retention parsing block from a trusted CD3 2026.1.0 checkout:

```bash
CD3_SOURCE_DIR=/absolute/path/to/cd3-automation-toolkit \
  python3 -m unittest discover -s tests -v
```

Validation performed for this package: 12 offline checks passed, including the
three parser-contract checks against the pinned upstream source. No live OCI
authorization test, full CD3 generation, or Terraform provider plan was executed.

## Sources

1. [Oracle Object Storage IAM permissions](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/objectstoragepolicyreference.htm).
2. [Oracle retention behavior and constraints](https://docs.oracle.com/en-us/iaas/Content/Object/Tasks/usingretentionrules.htm).
3. [OCI policy grants, inheritance, and attachment](https://docs.oracle.com/en-us/iaas/Content/Identity/Concepts/policies.htm).
4. [Oracle CD3 2026.1.0 source](https://github.com/oracle-devrel/cd3-automation-toolkit/tree/007e63050fc3da20253f008c4762fa8f9b0a8dec):
   `cd3_automation_toolkit/ocicloud/python/identity/policies/create_terraform_policies.py`,
   `ocicloud/python/storage/objectstorage/create_terraform_oss.py`,
   `ocicloud/python/storage/objectstorage/templates/oss-template`, and
   `ocicloud/terraform/object-storage.tf` (the latter three also under `cd3_automation_toolkit`).
5. [OCI Terraform bucket resource](https://docs.oracle.com/en-us/iaas/tools/terraform-provider-oci/latest/docs/r/objectstorage_bucket.html).

Version-specific parser checks use upstream commit
`007e63050fc3da20253f008c4762fa8f9b0a8dec`. Recheck the installed release before use.
