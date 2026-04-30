# Scripts

This directory contains helper scripts and configuration files used during bootstrap and validation.

> **Status:** Work in progress — populated alongside the Terraform and runbook phases.

---

## Structure

```
scripts/
├── bootstrap/
│   └── cloudwatch-agent-config.json    # CloudWatch Agent configuration
│                                        # Stored in SSM Parameter Store at
│                                        # /cloudops/dev/cloudwatch-agent/config/standard
└── validation/
    └── post-deploy-checks.sh           # Smoke tests run after terraform apply
                                         # Verifies: SSM reachability, CW Agent status,
                                         # heartbeat-api /health response, backup vault exists
```

---

## Notes

- Scripts are not idempotent deployment tools. They are operational helpers.
- `post-deploy-checks.sh` requires AWS CLI v2 + SSM Session Manager plugin.
- `cloudwatch-agent-config.json` is the source of truth for the Parameter Store value. Update here first, then push to Parameter Store via the `cloudops-refresh-cwagent` Run Command document.
