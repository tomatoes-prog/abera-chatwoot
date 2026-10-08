# Lite group backup and offline recovery

This is a recovery candidate. The automatic account BACKUP also records one
verified full group copy per ISO week. Managed RDS groups keep their separate
recovery path. A subscription RESTORE must never restore a whole group.

The copy uses PostgreSQL 16 custom format and a repeatable-read snapshot. It
includes all public tables, independent copies of attachment object versions,
and the original application encryption keys in private KMS-encrypted objects.
Each object is read back by version and SHA256. An isolated temporary PostgreSQL
database verifies that the stored dump restores and matches all table counts.
The completed weekly manifest is reused on retry.

## Operator requirements

Do not invoke GROUP_RESTORE through a purchase or a tenant RESTORE. Prepare a
reviewed group recovery with the common control plane and inventory retained
EBS, secrets, networking, object versions and operations first. This command
does not rebuild EC2, change routes or enable ingress.

Recovery requires all of the following:

- Lite, the original ABERA_GROUP_ID, and explicit `confirmGroupId` in the command.
- `ABERA_GROUP_RECOVERY_MODE=offline`, no application/Sidekiq writers and closed ingress.
- An empty database, the original four runtime encryption keys, and the same
  source SHA/product version as the backup.
- A groupBackup reference containing exact manifestKey, manifestVersionId and
  manifestSha256, with the original subscription/environment command context.
- Access to the private backup bucket, original KMS key and attachment bucket.

After restoring and checking table counts, every restored subscription is set
to `quiescing`. Reconcile each entitlement, assignment, pending operation and
route against current Billing/control-plane records. Only a reviewed recovery
may release that fence and reopen ingress.

## Failures and retry

Never discard the backup on failure. pg_restore uses a single transaction. A
failure before database commit can be retried with the same pinned reference
while the destination remains empty and offline. Restored attachment objects
are versioned; retries use the same keys and verify the stored bytes.

If the database already contains tables, the command refuses to overwrite it.
A crash after commit, a verification failure or an uncertain result requires
inspection of that destination before another restore. Keep it fenced, compare
the pinned manifest, table counts and current entitlements, and complete the
recovery or prepare a separate empty destination through a reviewed operation.
Do not erase a database or a control-plane lock to force the command to pass.

The common end-to-end group-recovery orchestration and reconciliation remain
pending; a passed local test does not certify AWS recovery. Capacity tests must
include space for the dump plus a temporary verification database. The current
single PutObject upload has a 5 GiB object limit, so this candidate cannot yet
be approved for larger dumps. Weekly recovery can lose up to seven days of data
only when a valid weekly copy exists; monitor actual receipt age before making
that commitment.
