# harlly-review-project

Hourly pipeline from Harlyy (customer surveys, incidents, Google and Chowdeck reviews)
into Redshift, built the same way as coldstone-web:

```
Glue trigger (hourly) -> harlyy-extract (Glue) -> SNS events -> SQS load queue
  -> load dispatcher (Lambda) -> harlyy-load (Glue) -> Redshift harlyy_feedback_analytics
failures -> SNS alerts -> email
```

| Path | What it is |
|---|---|
| `glue/harlyy_extract.py` | Harlyy API -> S3 raw JSON -> data quality checks -> S3 Parquet + manifest |
| `glue/harlyy_load.py` | manifest -> staging -> checks -> one MERGE transaction into `harlyy_feedback_analytics` |
| `lambda/load_dispatcher/handler.py` | starts the load job for each successful extract |
| `sql/redshift/01_tables.sql` | target + staging tables (`python glue/harlyy_extract.py --print-ddl`) |
| `sql/redshift/02_grants.sql` | Redshift access for the Glue role |
| `cloud_infra/` | Terraform for all of the above |
| `tests/` | offline tests (`pytest`) |

## First deployment

1. `cloud_infra/bootstrap`: `terraform init && terraform apply` (state bucket, once).
2. `cloud_infra`: fill in `redshift_database` in `terraform.tfvars`, set `schedule_enabled = false`,
   then `terraform init -backend-config=backend.hcl && terraform apply`.
3. Set the Harlyy secret:
   `aws ssm put-parameter --name /harlyy-feedback/prod/harlyy-client-secret --type SecureString --overwrite --value "<secret>"`
4. In Redshift, run `sql/redshift/01_tables.sql`, then `sql/redshift/02_grants.sql`.
5. Confirm the AWS subscription email for alerts.
6. Backfill: run the `eatngo-harlyy-feedback-extract` Glue job once with `--full-history true`.
   It loads everything up to the start of the current hour; the load starts automatically.
7. Set `schedule_enabled = true` and `terraform apply`: hourly runs start.

## One-off runs (Glue job parameters for that run only)

| Parameter | Effect |
|---|---|
| `--full-history true` | everything since Harlyy's first record (reviews from `REVIEWS_FROM`) |
| `--reviews-from 2023` | with `--full-history`: reviews from that year or date. Hourly runs keep every review Harlyy re-syncs, whatever its age |
| `--hour 2026-10-21T09` | one hour, e.g. a missed run |
| `--date 2026-10-20` | one whole day |
| `--from-raw true` | rebuild Parquet from the run's saved raw files, no API calls |

## Local test

```
pip install -r requirements.txt
python glue/harlyy_extract.py --local-dir output   # writes under output/, needs HARLYY_* in .env
pytest -q tests
```
