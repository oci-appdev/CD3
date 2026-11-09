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

## Dedicated logging compartment — complete setup procedure

Added 9 November 2026. This procedure fills the missing setup before the retention steps below. It is a runbook, not evidence of a completed OCI deployment. Console wording can vary by release; use Console search for the named service when navigation differs.

### 1. Confirm the destination and record inputs

Use the existing Default identity domain and existing ADFS/YubiKey access. No new identity domain, VCN, subnet, or VM is required just to create this compartment.

| Item | Planned value / required action |
| --- | --- |
| Compartment hierarchy | Tenancy → EBLZ → VDMS → Logging |
| Regional logging and bucket location | us-langley-1; confirm subscribed Government Cloud region |
| IAM changes | Use the actual tenancy home region |
| Evidence bucket | eblz-security-evidence-worm; confirm name availability |
| Searchable logs | Proposed 90 days; confirm approved retention and supported setting |
| Object retention | Proposed seven years; obtain the actual records requirement |
| Owner | Existing VDMS platform/logging administrators |
| Evidence readers | Existing Security-Auditors group |
| Lock authority | Separately approved security group |

Before creation, search Compartments for Logging and inspect its parent and OCID. The older workbook uses EBLZ::Logging. Do not treat it as the same compartment as EBLZ::VDMS::Logging, delete it, or move its resources as part of this setup. If an existing operational logging destination is to be retained, substitute that confirmed compartment everywhere below and record the decision. A migration requires its own resource inventory and plan.

Record locally: EBLZ OCID, VDMS OCID, Logging OCID when created, operator group OCID, auditor group OCID, source compartment/log OCIDs, and approved alert recipients. Keep production identifiers and evidence out of this public repository.

### 2. Create the Logging compartment in the Console

Use an existing IAM administrator authorized to create compartments beneath VDMS.

1. Sign in to the Government Cloud Console using the existing federated account.
2. Open **Identity & Security → Compartments** (or search for Compartments).
3. Open EBLZ. Verify its OCID against the recorded landing-zone parent.
4. Open its VDMS child. Verify the parent is EBLZ.
5. Select **Create compartment**.
6. Enter name **Logging**.
7. Enter description: **Central log groups, log delivery connectors, and retained security evidence for the EBLZ landing zone**.
8. Set **Parent compartment = VDMS**. Check the hierarchy, not only the display name.
9. Apply only existing, approved defined tags. Confirm their namespaces and keys exist first; an invented tag can cause the Invalid tags error seen previously. Meet any required tag defaults.
10. Select **Create compartment**.
11. Wait for **Active**, open Logging, and copy its OCID into the restricted implementation record.
12. Verify the breadcrumb is **EBLZ → VDMS → Logging**.

Success: one Active Logging child beneath VDMS. An empty compartment does not collect logs automatically and cannot itself be retention-locked.

### 3. Alternative: create the compartment through CD3

Use either step 2 or this step to create it, not both. If step 2 was used, reconcile/import the existing resource into the intended Terraform state before managing it through CD3.

1. Back up the authoritative workbook and state.
2. Open the **Compartments** worksheet. Read its header instructions for the installed CD3 version.
3. Confirm EBLZ and VDMS are already represented with their existing mappings.
4. Insert a row before **<END>** for **Logging**, with parent **EBLZ::VDMS**, using the sheet's compartment-name and parent-compartment columns.
5. Use the installed CD3 alias for the actual IAM home region. Do not copy Ashburn from the old workbook without checking the region mapping.
6. Supply the same description as step 2 and only valid existing tags.
7. Run the established CD3 entry command and choose **Identity → Add/Modify/Delete Compartments**.
8. Review generated Terraform: Logging's parent compartment ID must resolve to VDMS, not tenancy root or EBLZ.
9. Run Terraform validation and a saved plan, or the equivalent Resource Manager Plan job.
10. Confirm the plan creates only the intended missing compartment and does not rename, replace, or remove existing compartments.
11. Apply the reviewed plan with the established deployment identity.
12. Read back the new compartment OCID and parent; record them.

Do not edit an old EBLZ::Logging row to repurpose an existing compartment without a separate move/state review. Keep one state owner per resource.

### 4. Add logging operator and reader permissions

Use an existing IAM policy at Logging or an ancestor that can govern it. Given the reported IAM policy-object limit, append statements to an existing appropriate policy rather than creating a new object. Preserve all existing statements.

Replace placeholders below. Use group OCIDs to avoid identity-domain name ambiguity:

```text
Allow group id <LOGGING_OPERATORS_GROUP_OCID> to manage log-groups in compartment id <LOGGING_COMPARTMENT_OCID>
Allow group id <LOGGING_OPERATORS_GROUP_OCID> to read log-content in compartment id <LOGGING_COMPARTMENT_OCID>
Allow group id <LOGGING_OPERATORS_GROUP_OCID> to manage serviceconnectors in compartment id <LOGGING_COMPARTMENT_OCID>
Allow group id <AUDITORS_GROUP_OCID> to read log-groups in compartment id <LOGGING_COMPARTMENT_OCID>
Allow group id <AUDITORS_GROUP_OCID> to read log-content in compartment id <LOGGING_COMPARTMENT_OCID>
Allow group id <AUDITORS_GROUP_OCID> to read buckets in compartment id <LOGGING_COMPARTMENT_OCID>
Allow group id <AUDITORS_GROUP_OCID> to read objects in compartment id <LOGGING_COMPARTMENT_OCID> where target.bucket.name='eblz-security-evidence-worm'
```

These are scoped supplements. Resource owners still need their service-specific permissions to enable logging on source resources. Connector-source access and bucket administration are configured separately below. Existing compartment discovery, tag namespace use, and deployment-state permissions remain prerequisites.

For CD3, add each full statement as one continuation row in the existing Policies block, as explained in retention step 4 below. Generate and review the policy diff before apply. Verify the operator can open Logging and create a log group; verify auditors can read but have no unintended write grants. IAM permissions are additive: a narrow new statement does not cancel broad inherited access.

### 5. Create central log groups

In the region selector choose **us-langley-1**.

1. Open **Observability & Management → Logging → Log Groups**.
2. Select **EBLZ → VDMS → Logging** in the compartment picker.
3. Select **Create log group**.
4. Name it **eblz-network-security**; describe its purpose as network and security service logs.
5. Apply approved tags and create it.
6. Repeat for **eblz-platform** and **eblz-log-delivery**.
7. Open each group and record its OCID and compartment.

Use network-security for supported network/firewall/WAF logs, platform for other approved service/custom logs, and log-delivery for connector diagnostics where available. Log groups organize logs; choose searchable retention on each log. Audit is collected by OCI separately: do not create a custom group named _Audit expecting to enable Audit collection.

### 6. Enable each required source log

Create a source inventory before enabling anything:

| Source resource | Source compartment | Region | Log category | Destination log group | Enabled / event verified |
| --- | --- | --- | --- | --- | --- |
| Approved subnet or VNIC | Record actual | Record actual | Supported flow-log category | eblz-network-security | Pending |
| Existing firewall / WAF | Record actual | Record actual | Categories offered by the service | eblz-network-security | Pending |
| Existing platform service | Record actual | Record actual | Supported service category | eblz-platform | Pending |
| Audit | Every required compartment, including root where needed | Record actual | _Audit source | Selected separately by connector | Pending |

For each service resource:
1. Open **Logging → Logs → Enable service log**.
2. Select the compartment holding the source resource, its service, resource, and offered log category.
3. Set the log destination compartment to Logging and choose the intended central log group where supported.
4. Give the log a descriptive name containing service/resource/category.
5. Set approved searchable retention, for example 90 days if supported, and enable it.
6. Wait for Active, generate one harmless representative event (for example an approved connection), and use **Explore log/Search** to verify a recent timestamp and expected resource identity.
7. Repeat for each required category and resource; enabling one log does not enable every log in a VCN or tenancy.

If a service requires its log to stay with the source compartment, keep it there and select it as a connector source. Check Government Cloud availability for each category; do not deploy a new firewall or WAF merely to populate this inventory. Guest OS logs require a separate supported agent/custom-log setup; service-log enablement does not collect VM files automatically.

### 7. Create the private evidence bucket

1. Open **Storage → Buckets**, select us-langley-1 and the new Logging compartment.
2. Select **Create bucket**.
3. Enter **eblz-security-evidence-worm** (or the approved unique name).
4. Select **Standard**, private visibility, and versioning disabled for this new bucket.
5. Use the approved encryption setting. If using a customer-managed Vault key, verify service access and key lifecycle before proceeding.
6. Leave replication and retention lock unconfigured for initial delivery testing. Do not create public access or pre-authenticated requests.
7. Create the bucket and verify its compartment OCID, region, visibility, and versioning.
8. Record its namespace and name.

An authorized storage administrator creates this bucket, or use the CD3 bucket procedure below and optional creation template. Do not use the Terraform-state bucket for evidence.

### 8. Configure Connector Hub delivery

1. Open **Connector Hub → Connectors**, select Logging, and create a connector named **eblz-security-logs-to-evidence**.
2. Set source **Logging**, target **Object Storage**, and no processing task for this initial setup.
3. Select every approved source log from step 6. Add the required Audit sources separately; explicitly verify compartment coverage instead of assuming a parent selection recursively includes all children.
4. Select the evidence bucket in Logging as the target. Use the Console's supported default batching settings initially and record them.
5. Review the source and target authorization statements offered by the connector wizard. Have the IAM administrator append the required statements to an existing suitable policy; do not automatically create extra policy objects.
6. Scope source access to the chosen source compartments/logs and target writes to the evidence bucket and intended connector identity. Human operator permissions alone do not authorize the connector.
7. Reopen/review the wizard after policy propagation and create/activate the connector.
8. Enable connector diagnostics into eblz-log-delivery if offered in this Government Cloud region.

Keep this connector's diagnostic log out of its own source selection to avoid feedback. For exact generated service-principal authorization, use the wizard's current statements for this configuration instead of guessing a dynamic-group rule. Copy them into the authoritative CD3 policy source after validation.

### 9. Prove end-to-end collection before retention

1. Record a UTC start time and generate an approved identifiable test event.
2. Find that event in Logging Search.
3. Check connector state and metrics/diagnostics for successful processing.
4. After the configured batch interval and delivery processing, list the evidence bucket.
5. Download a newly delivered object with the auditor identity.
6. Decompress if necessary and locate the test event, timestamp, and source identifier.
7. Repeat for Audit and each distinct source category; a single delivered file does not prove complete coverage.
8. Record source-to-object evidence in the restricted change record.

Connector Hub does not provide a general historical backfill merely by creating a connector. Its Logging source delivery window is limited; resolve failures promptly and separately account for historical gaps. See Oracle's delivery documentation below.

### 10. Enable retention, lifecycle, and operational monitoring

1. Continue with retention steps 1–8 below: apply the approved time-bound rule **without a lock**, using the same state owner.
2. Test overwrite/delete protection only on disposable test objects with an identity otherwise allowed those actions; verify production delivery continues.
3. If approved, configure a bucket lifecycle transition to Archive after 90 days. Verify required lifecycle service authorization. Test restoring archived evidence before relying on it.
4. Configure monitoring for connector failures and missing expected delivery; choose thresholds using the actual batch interval and normal source frequency. A quiet source alone is not proof of failure.
5. Create/use the approved Notifications topic, subscribe the operational mailbox, and confirm the subscription. Verify receipt with an approved test notification.
6. Only after acceptance, follow retention step 9 to schedule permanent locking with at least the mandatory 14-day delay. Record the approver and review dates.
7. Reconcile all Console-created resources with the authoritative CD3/Terraform configuration before the next automated apply.

The lock applies to the bucket retention rule, not Logging or the compartment. Archive transitions are compatible with retention; deletion remains blocked while objects are protected. A permanent lock cannot be undone.

### 11. Completion and troubleshooting

| Check | Required evidence |
| --- | --- |
| Compartment | Active; parent OCID is VDMS |
| IAM | Operator and auditor checks; broad inherited grants reviewed |
| Log coverage | Every inventory row has a verified recent event or documented exception |
| Delivery | Representative events found inside delivered objects |
| Retention | Correct duration; lock absent initially |
| Monitoring | Confirmed recipient and successful test notification |
| CD3 ownership | Workbook/configuration and owning state reconciled |

- **Logging missing from picker:** check region, permissions, compartment parent and propagation.
- **Invalid tags:** verify namespace, key, allowed value and tag permissions.
- **No source events:** check source resource/category, enablement, time range and log location.
- **Source events but no objects:** check connector authorization, target namespace/bucket, batching and failure diagnostics.
- **Quota blocks setup:** inspect the exact service quota; do not disable unrelated SCCA guardrails.
- **Duplicate resources in plan:** stop and reconcile existing resource imports/state before applying.
- **Rollback before lock:** disable only the newly introduced failing connector/log configuration as appropriate; preserve collected evidence and repair forward. Do not delete a populated compartment as rollback.
- **After permanent lock:** reverting Git cannot remove protected retention.

### Setup references

- [Create a log group](https://docs.oracle.com/en-us/iaas/Content/Logging/Task/create-logging-log-group.htm)
- [Enable resource logging](https://docs.oracle.com/en-us/iaas/Content/Logging/Task/enabling_logging.htm)
- [Create a Logging-source connector and understand its delivery window](https://docs.oracle.com/en-us/iaas/Content/connector-hub/create-service-connector-logging-source.htm)
- [Retention behavior and restrictions](https://docs.oracle.com/en-us/iaas/Content/Object/Tasks/usingretentionrules.htm)

---

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
