# Runbook

All AWS changes go through GitHub Actions. Nobody runs `terraform apply` from a laptop (except
the one-time bootstrap and the free-plan check below).

## 0. Check the free plan allows what we use (week 1, about an hour)

```bash
cd infra/freeplan-check
terraform init && terraform apply     # ECS Fargate + an ALB with a public nginx image
# open the printed URL (give it a couple of minutes), then:
terraform destroy                     # right away: the ALB bills by the hour
```

Also look at Service Quotas for the Fargate vCPU limit on new accounts (it can be as low as 6).
Add up the vCPUs of everything that runs at once: 2 x 0.25 (API) + 0.5 (dashboard) + 0.5 (a job).

If Fargate or the ALB is blocked, the fallback is a Lambda-based design (or the club's DS3 account).

## 1. One-time setup

1. One person creates the AWS account on the **Free plan** (never upgrade to the Paid plan) and
   turns on MFA for the root user. Everyone else gets their own IAM user.
2. Apply the bootstrap stack by hand (local state; keep the state file safe or migrate it later):

   ```bash
   cd infra/bootstrap
   terraform init
   terraform apply -var state_bucket_name=<globally-unique-name> -var github_repo=<owner>/<repo>
   ```

3. In GitHub, **Settings > Secrets and variables > Actions > Variables**, add:

   | Variable | Value |
   |----------|-------|
   | `AWS_ROLE_ARN` | `github_actions_role_arn` output from bootstrap |
   | `TF_STATE_BUCKET` | the state bucket name |
   | `AWS_REGION` | e.g. `us-east-1` (optional) |
   | `NIGHTLY_DESTROY` | `true` to destroy the serving stack every night (recommended) |

   Never commit credentials or API keys: this repo is public.

## 2. Bring the system up

Run the **deploy** workflow with action `up`. It applies base, builds and pushes the image, applies
training and serving, runs the pipeline once, and prints the URL (plain HTTP).

- Dashboard: `http://<alb-dns>/`
- API docs: `http://<alb-dns>/docs`
- CLI: `export CARBON_API_URL=http://<alb-dns>`

First deploys usually take a few tries: ECS services fail if the image is not in ECR yet (the
workflow orders this), and tasks that exit immediately are usually an architecture mismatch
(build for `linux/amd64`) or a missing log group. Check CloudWatch Logs under `/ecs/carbon-windows`.

## 3. Resilience demo

Healthy: show the dashboard, `carbon-windows status`, `curl http://<alb-dns>/v1/health`.

**Pipeline fails.** Make a step crash, then run the pipeline:

```bash
./scripts/tf.sh training apply -auto-approve -var fail_step=train
./scripts/run_pipeline.sh            # ends FAILED; Step Functions records the failure and alerts SNS
carbon-windows best -d 4 -w 1d       # still answers, exit code 4, warning: pipeline_failed
```

The dashboard shows a banner, the status record has the error, and (if you set `alert_email`) an
email arrives. Fix it with `-var fail_step=` and run the pipeline again.

**Pipeline stops running.** Nothing records a failure here, so the API notices the forecast aging:

```bash
./scripts/tf.sh serving apply -auto-approve -var stale_after_hours=0.05   # about 3 minutes
# wait a few minutes: warnings now include forecast_stale
./scripts/tf.sh serving apply -auto-approve                                # reset to 6 hours
```

**An AZ or task dies.** Stop one API task in the ECS console. The ALB health check routes around it
and ECS starts a replacement; requests keep succeeding.

## 4. Schedules

Pipeline and accuracy schedules are disabled by default (every run costs a little). Enable them
for a demo by running deploy with `schedules_enabled` checked, or:

```bash
./scripts/tf.sh training apply -auto-approve -var schedules_enabled=true
```

The refresh cadence is `pipeline_schedule` (default every 3 hours, a placeholder).

## 5. Tear down

- Nightly: the **nightly-destroy** workflow removes the serving stack (needs `NIGHTLY_DESTROY=true`).
  Turn it off before a demo.
- After the demo: record a video and screenshots first, then run **deploy** with `down-all`.
  Bootstrap (state bucket and the GitHub role) stays; delete it by hand if you want.
- Buckets and the ECR repo are set to force-delete, so destroy will not stall on non-empty ones.

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| API returns 503 `no_forecast` | The pipeline has not run yet. Run `./scripts/run_pipeline.sh`. |
| Targets unhealthy in the ALB | Health check grace period, a crashing container (see logs), or the wrong image architecture. |
| Pipeline fails at `ingest` | Data source unreachable or validation rejected the batch (a gap longer than 3 hours). |
| `terraform destroy` stalls | Something outside Terraform is using the resources (a running task, files in a bucket you did not create through Terraform). |
| Unexpected credit use | The ALB left running. Check what is up: `./scripts/tf.sh serving state list`. |
