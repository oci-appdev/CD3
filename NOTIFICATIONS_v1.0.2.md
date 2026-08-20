# OCI CD3 Backup v1.0.2 — Email Notification Setup

This runbook configures email alerts for the CD3 backup package. Follow the
steps in order. Do not consider alerting complete until the test email arrives.

## What you are setting up

```text
CD3 backup script ──publishes──> OCI Notifications topic ──sends──> Email or distribution list
        │
        └──systemd OnFailure backstop──> same OCI Notifications topic
```

The normal backup script reports success, validation failures and backup
failures. The systemd backstop reports failures that can prevent the script
from reporting for itself, such as an OOM kill, timeout kill or missing script.

## Choose one setup method

| Method | When to use it | Recommendation |
|---|---|---|
| **Method A — OCI Console** | An OCI administrator can create the topic and subscription | **Recommended.** The CD3 instance receives publish-only runtime access. |
| **Method B — Setup script** | You are authorized to let the CD3 instance create the topic and subscriptions | Faster, but requires temporary broader IAM permissions. |

Do not combine the two methods. Complete Method A or Method B, then continue to
**Configure the CD3 backup files**.

## Values you need

Collect these before starting:

| Value | Example |
|---|---|
| CD3 instance dynamic group | `CD3-Backup-Instances` |
| Notifications compartment | `EBLZ-Operations` |
| Notifications compartment OCID | `ocid1.compartment...` |
| Topic name | `cd3-backup-alerts` |
| Recipient | `dl-cd3-alerts@example.gov` |
| Environment label | `PROD-SCCA` |

Prefer a monitored distribution list over one person's mailbox.

---

# Method A — Create the topic in the OCI Console

This is the recommended least-privilege method.

## A1. Create the Notifications topic

1. Sign in to the OCI Console with an administrator account.
2. Select the correct Government Cloud region.
3. Open **Developer Services**.
4. Under **Application Integration**, select **Notifications**.
5. Select the compartment where the notification topic will live.
6. Select **Create Topic**.
7. Enter:

   - **Name:** `cd3-backup-alerts`
   - **Description:** `Success and failure alerts for CD3 instance backups`

8. Select **Create**.
9. Open the new topic.
10. Copy its **Topic OCID**. You will add it to the CD3 configuration later.

## A2. Create the email subscription

1. On the `cd3-backup-alerts` topic page, select **Subscriptions**.
2. Select **Create Subscription**.
3. For **Protocol**, select **Email**.
4. Enter the email address or distribution list.
5. Select **Create**.

The subscription will initially show **PENDING**. That is expected.

## A3. Confirm the subscription

1. Open the confirmation message OCI sends to the subscribed address.
2. Select **Confirm subscription** within three days.
3. Return to the topic's **Subscriptions** page.
4. Confirm the subscription status is **ACTIVE**.

**No backup email will be delivered while the subscription is PENDING.**

If the recipient is a distribution list, make sure the confirmation message is
not blocked or waiting for moderation.

## A4. Grant the CD3 instance runtime access

Create this IAM policy statement in the tenancy home region. Replace the
compartment name with the compartment containing the Notifications topic:

```text
Allow dynamic-group CD3-Backup-Instances to use ons-topics in compartment <NOTIFICATIONS_COMPARTMENT_NAME>
```

Example:

```text
Allow dynamic-group CD3-Backup-Instances to use ons-topics in compartment EBLZ-Operations
```

This runtime policy lets the instance read the configured topic and publish
messages. It does not let the instance create or delete topics.

Allow several minutes for a new IAM policy to propagate.

Continue to **Configure the CD3 backup files**.

---

# Method B — Create the topic with the setup script

Use this method only if the CD3 instance is authorized to create the topic and
email subscriptions.

## B1. Add temporary setup permissions

Temporarily add these statements to the CD3 dynamic-group policy:

```text
Allow dynamic-group CD3-Backup-Instances to manage ons-topics in compartment <NOTIFICATIONS_COMPARTMENT_NAME>
Allow dynamic-group CD3-Backup-Instances to manage ons-subscriptions in compartment <NOTIFICATIONS_COMPARTMENT_NAME>
```

Also keep the runtime statement:

```text
Allow dynamic-group CD3-Backup-Instances to use ons-topics in compartment <NOTIFICATIONS_COMPARTMENT_NAME>
```

Wait several minutes for IAM propagation.

## B2. Preview the setup

Run the command without `--execute`. This changes nothing:

```bash
sudo -u opc /opt/cd3-backup/setup_cd3_notifications.sh \
  --config /etc/cd3-backup/cd3-backup.conf \
  --topic-name cd3-backup-alerts \
  --compartment-id <NOTIFICATIONS_COMPARTMENT_OCID> \
  --email dl-cd3-alerts@example.gov
```

Review the region, compartment, topic name and recipient printed on the screen.

If the topic belongs in the same compartment as the CD3 instance, the script
can discover the compartment automatically and `--compartment-id` may be
omitted. Supplying it explicitly is clearer and prevents creation in the wrong
compartment.

For several recipients, repeat `--email`:

```bash
--email first@example.gov --email second@example.gov
```

## B3. Create the topic and subscription

Run the same command with `--execute`:

```bash
sudo -u opc /opt/cd3-backup/setup_cd3_notifications.sh \
  --config /etc/cd3-backup/cd3-backup.conf \
  --topic-name cd3-backup-alerts \
  --compartment-id <NOTIFICATIONS_COMPARTMENT_OCID> \
  --email dl-cd3-alerts@example.gov \
  --execute
```

The script safely reuses an existing topic with the same name and skips an
address it finds already subscribed.

At the end, copy the complete line printed by the script:

```bash
ONS_TOPIC_OCID="ocid1.onstopic..."
```

## B4. Confirm the subscription

1. Open the confirmation message sent by OCI.
2. Select **Confirm subscription** within three days.
3. In the OCI Console, open **Notifications** → `cd3-backup-alerts` →
   **Subscriptions**.
4. Confirm the status is **ACTIVE**.

## B5. Remove the temporary permissions

After topic creation is complete, remove these two temporary statements:

```text
Allow dynamic-group CD3-Backup-Instances to manage ons-topics in compartment <NOTIFICATIONS_COMPARTMENT_NAME>
Allow dynamic-group CD3-Backup-Instances to manage ons-subscriptions in compartment <NOTIFICATIONS_COMPARTMENT_NAME>
```

Keep this runtime statement:

```text
Allow dynamic-group CD3-Backup-Instances to use ons-topics in compartment <NOTIFICATIONS_COMPARTMENT_NAME>
```

---

# Configure the CD3 backup files

Complete the following steps regardless of which setup method you used.

## Step 1. Confirm the v1.0.2 notification files are installed

The following files must exist:

```text
/opt/cd3-backup/backup_cd3_instance.sh
/opt/cd3-backup/cd3-backup-notify.sh
/etc/systemd/system/cd3-backup.service
/etc/systemd/system/cd3-backup-failure.service
/etc/cd3-backup/cd3-backup.conf
```

Check them:

```bash
sudo ls -l \
  /opt/cd3-backup/backup_cd3_instance.sh \
  /opt/cd3-backup/cd3-backup-notify.sh \
  /etc/systemd/system/cd3-backup.service \
  /etc/systemd/system/cd3-backup-failure.service \
  /etc/cd3-backup/cd3-backup.conf
```

If the notifier and failure unit have not been installed, run these commands
from the extracted v1.0.2 package directory:

```bash
sudo install -o opc -g opc -m 0750 \
  cd3-backup-notify.sh /opt/cd3-backup/

sudo install -o opc -g opc -m 0750 \
  setup_cd3_notifications.sh /opt/cd3-backup/

sudo install -m 0644 \
  cd3-backup.service /etc/systemd/system/

sudo install -m 0644 \
  cd3-backup-failure.service /etc/systemd/system/

sudo systemctl daemon-reload
```

If CD3 runs under a Linux account other than `opc`, replace the owner and group
and update `User=` and `Group=` in both systemd units.

## Step 2. Add the topic OCID and notification preferences

Edit the backup configuration:

```bash
sudo vi /etc/cd3-backup/cd3-backup.conf
```

Set these values:

```bash
ONS_TOPIC_OCID="ocid1.onstopic.REPLACE_WITH_YOUR_TOPIC_OCID"

NOTIFY_ON_SUCCESS=true
NOTIFY_ON_FAILURE=true
NOTIFY_ON_VERIFY=true
NOTIFY_ON_DRY_RUN=false

NOTIFY_SUBJECT_PREFIX="[CD3 Backup]"
NOTIFY_ENVIRONMENT="PROD-SCCA"

REQUIRE_NOTIFICATION_TOPIC=false
```

During initial setup, leave `REQUIRE_NOTIFICATION_TOPIC=false`. After the
end-to-end test succeeds, you may set it to `true` if your policy requires the
backup to refuse to run whenever the topic cannot be validated.

Protect the configuration:

```bash
sudo chown root:opc /etc/cd3-backup/cd3-backup.conf
sudo chmod 0640 /etc/cd3-backup/cd3-backup.conf
```

## Step 3. Send the required end-to-end test

Run:

```bash
sudo -u opc /opt/cd3-backup/backup_cd3_instance.sh \
  --config /etc/cd3-backup/cd3-backup.conf \
  --test-notification
```

Expected command result:

```text
Test notification published. Confirm it arrived before relying on backup alerting.
```

Expected email subject:

```text
[CD3 Backup] PROD-SCCA TEST - <CD3-INSTANCE-NAME>
```

This test does **not** create a backup.

Do not continue until:

- The command exits successfully.
- The test message arrives in the intended mailbox or distribution list.
- The subject contains the expected environment name.

## Step 4. Confirm the systemd failure backstop is connected

Reload systemd and inspect the backup unit:

```bash
sudo systemctl daemon-reload
systemctl show cd3-backup.service -p OnFailure
```

Expected result:

```text
OnFailure=cd3-backup-failure.service
```

## Step 5. Test the standalone notifier

This sends another test email without creating a backup:

```bash
sudo -u opc /opt/cd3-backup/cd3-backup-notify.sh \
  --config /etc/cd3-backup/cd3-backup.conf \
  --state test \
  --message "Manual CD3 notification validation"
```

Expected result:

```text
Notification published: [CD3 Backup] PROD-SCCA TEST - <CD3-INSTANCE-NAME>
```

## Step 6. Test the systemd failure handler

Notify the operations team before this test because the email subject says
`FAILED`.

```bash
sudo systemctl start cd3-backup-failure.service
sudo journalctl -u cd3-backup-failure.service -n 30 --no-pager
```

Expected results:

- The unit completes successfully.
- A failure-backstop email arrives.
- The journal contains `Notification published`.

This command tests only the notification backstop. It does not create or delete
a backup.

## Step 7. Verify the daily service and timer

```bash
sudo systemctl enable --now cd3-backup.timer
systemctl list-timers cd3-backup.timer
systemctl status cd3-backup.timer --no-pager
```

The supplied timer normally runs at 02:15 UTC with a randomized delay of up to
15 minutes.

---

# Final acceptance checklist

Alerting is ready only when every item below is true:

- [ ] The topic exists in the intended OCI region and compartment.
- [ ] The email subscription status is `ACTIVE`, not `PENDING`.
- [ ] `ONS_TOPIC_OCID` contains the complete topic OCID.
- [ ] The dynamic group has `use ons-topics` in the topic's compartment.
- [ ] `--test-notification` exits successfully.
- [ ] The end-to-end test email arrives.
- [ ] `OnFailure=cd3-backup-failure.service` is visible in systemd.
- [ ] The standalone notifier test arrives.
- [ ] The systemd failure-backstop email arrives.
- [ ] The daily timer is enabled and scheduled.

Do not rely on the alerting until the checklist is complete.

# What messages you will receive

| Event | Expected email |
|---|---|
| Backup succeeds | Backup ID, duration, OCI backup records, Object Storage path and verification command |
| Backup fails | Failure stage, reason, exit code and investigation command |
| A safety guard refuses the run | The guard name and specific refusal reason |
| Verification passes or fails | Verification result and backup ID |
| Script is killed or cannot start | Systemd failure-backstop email |
| Dry run | No email unless `NOTIFY_ON_DRY_RUN=true` |

Two emails can be received for one timeout or kill. One may come from the
script and the other from systemd. This is expected.

# Troubleshooting

| Symptom | Most likely cause | Corrective action |
|---|---|---|
| Setup script returns `NotAuthorizedOrNotFound` | Method B permissions are missing or scoped to the wrong compartment | Add the temporary `manage` statements, verify the compartment and wait for IAM propagation |
| Test reports that the topic cannot be read | Wrong topic OCID, wrong region or missing `use ons-topics` | Copy the OCID again and verify the policy scope |
| Test command succeeds but no email arrives | Subscription is still `PENDING`, email is filtered, or a distribution list blocks it | Confirm the subscription, check spam/quarantine and allow the OCI sender through the distribution list |
| Confirmation link expired | The link was not selected within three days | Re-create the subscription or resend its confirmation in OCI |
| `cd3-backup-failure.service` is not found | The v1.0.2 systemd unit was not installed or systemd was not reloaded | Install the unit and run `sudo systemctl daemon-reload` |
| `NOTIFICATION FAILED` appears in the journal | OCI rejected the publish request | Read the ONS response in the journal; check the OCID, region and IAM policy |
| Two failure emails arrive | Both the script and the systemd backstop reported the same failure | Expected for some kill and timeout scenarios |
| No email and no backup journal exists | The backup never started because the host or timer was unavailable | Check the host and `systemctl list-timers cd3-backup.timer`; add an external missed-run monitor |

Useful journal commands:

```bash
sudo journalctl -u cd3-backup.service -n 200 --no-pager
sudo journalctl -u cd3-backup-failure.service -n 100 --no-pager
sudo systemctl status cd3-backup.service --no-pager
sudo systemctl status cd3-backup.timer --no-pager
```

# Important remaining limitation

Notifications report runs that actually start. If the CD3 host is down, the
timer is disabled, or the unit is masked, the host cannot publish an alert.

Leave `NOTIFY_ON_SUCCESS=true` so a missing daily success message is noticeable
until an external OCI Monitoring missed-run alarm is implemented.

# Oracle references

- [Creating an OCI Notifications topic](https://docs.oracle.com/en-us/iaas/Content/Notification/Tasks/create-topic.htm)
- [Creating and confirming an email subscription](https://docs.oracle.com/en-us/iaas/Content/Notification/Tasks/create-subscription-email.htm)
- [Publishing a message to a topic](https://docs.oracle.com/en-us/iaas/Content/Notification/Tasks/publishingmessages.htm)
- [Notifications IAM policy reference](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/notificationpolicyreference.htm)
