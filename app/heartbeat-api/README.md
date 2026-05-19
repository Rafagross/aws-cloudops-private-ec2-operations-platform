# heartbeat-api

Minimal HTTP service embedded in the Golden AMI. Provides the observable
behavior (liveness signal, CPU load, Prometheus metrics) that CloudWatch
alarms monitor.

## Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/health` | GET | Liveness check. Returns `200 {"status":"ok", "uptime":"..."}` |
| `/metrics` | GET | Prometheus plaintext counters and uptime gauge |
| `/work?ms=N` | GET | Busy-wait for N ms (0–30000). Drives CPU alarms |

## Build (arm64 for Graviton)

```bash
cd app/heartbeat-api
make build
# output: dist/heartbeat-api
```

## CI

The workflow `.github/workflows/heartbeat-api.yml` runs `go test` and
builds the arm64 binary on every push that touches `app/heartbeat-api/**`.
The artifact is uploaded and referenced by the Image Builder component
for AMI bake.

## Image Builder integration

The component `heartbeat_api_install` in
`terraform/modules/image-builder/main.tf` downloads the binary from the
diagnostics S3 bucket during the AMI build.
Upload the artifact before running the pipeline:

```bash
# Build locally
make -C app/heartbeat-api build

# Upload to diagnostics bucket
aws s3 cp app/heartbeat-api/dist/heartbeat-api \
  s3://<diagnostics-bucket>/artifacts/heartbeat-api/heartbeat-api
```
