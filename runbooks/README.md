# Runbooks

This directory contains operational runbooks for the `aws-cloudops-private-ec2-operations-platform`.

Runbooks are written for operators who have AWS CLI access and the SSM Session Manager plugin installed.

> **Status:** Work in progress — Phase 5 of the project.

---

## Index

| Runbook | Scenario |
|---|---|
| [01-access-instance-via-ssm.md](01-access-instance-via-ssm.md) | Start an SSM session, port-forward to heartbeat-api, collect a diagnostic bundle |
| [02-rotate-golden-ami.md](02-rotate-golden-ami.md) | Trigger a new Image Builder pipeline run, validate the AMI, roll forward via Instance Refresh |
| [03-restore-from-backup.md](03-restore-from-backup.md) | Restore an EBS volume from an AWS Backup recovery point, validate data integrity |
| [04-investigate-failed-alarm.md](04-investigate-failed-alarm.md) | Triage a CloudWatch alarm, query logs with Logs Insights, determine root cause |
| [05-emergency-patch.md](05-emergency-patch.md) | Apply an out-of-cycle CVE patch outside the Maintenance Window |

---

## Conventions

- Every runbook starts with **Trigger** (what caused you to open this), **Prerequisites** (what you need before starting), and **Impact** (what changes during the procedure).
- Commands use `<placeholder>` syntax for values you must substitute.
- Each runbook ends with a **Validation** section — how to confirm the procedure succeeded.
- Runbooks are not automated scripts. They are human-readable procedures. Scripts that assist with steps live in `../scripts/`.
