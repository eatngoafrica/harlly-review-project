# CLAUDE.md

Hourly pipeline: Harlyy API (customer surveys, incidents, Google/Chowdeck reviews) → S3 → Redshift
Serverless schema `harlyy_feedback_analytics` (database `eatngo`), for Eat'N'Go (Domino's, Cold Stone,
Pinkberry; Nigeria and Kenya). Full data dictionary and runbook:
`doc/Harlyy_Feedback_Pipeline_Data_Dictionary_and_Runbook.md` (keep the `.pdf` beside it in sync).

```
Glue trigger (:05 hourly) -> glue/harlyy_extract.py -> SNS events -> SQS -> lambda/load_dispatcher
  -> glue/harlyy_load.py (COPY to harlyy_feedback_staging, checks, one MERGE transaction)
failures -> SNS alerts -> email
```

## Layout

| Path | Notes |
|---|---|
| `glue/harlyy_extract.py` | API → raw JSON → `build_tables()` → quality checks → Parquet + manifest; also registers Glue catalog partitions (Athena). **`TABLES` is the single source of truth** for columns, Redshift DDL, Parquet schema, manifest and Athena views |
| `glue/harlyy_load.py` | manifest → staging → checks → MERGE (upsert on key; child tables replaced per parent) |
| `lambda/load_dispatcher/handler.py` | starts the load per successful extract (Python 3.12) |
| `sql/redshift/01_tables.sql` | **generated**: `python glue/harlyy_extract.py --print-ddl > sql/redshift/01_tables.sql` (CI diffs it) |
| `sql/redshift/02..06_*.sql` | grants, reporting views, store map, negative-feedback alert feed, comment/response view. Run in number order |
| `sql/redshift/queries/` | saved analyst queries (dashboards, smilecard, backfill check, reconciliation) |
| `sql/athena/latest_views.sql` | **generated**: `--print-athena-views` |
| `tools/reconcile_with_harlyy.py` | compares Harlyy's analytics API (= the Harlyy app) with our transform for a period |
| `cloud_infra/` | Terraform (state in S3 `eatngo-terraform-statefile`); `bootstrap/` creates the state bucket |
| `tests/test_glue.py` | offline tests |

## Commands

```
pip install -r requirements.txt            # venv/ exists locally (Windows: venv/Scripts/python.exe)
pytest -q tests
ruff check --select E9,F --target-version py39 glue lambda tests tools
python glue/harlyy_extract.py --print-ddl > sql/redshift/01_tables.sql
python glue/harlyy_extract.py --local-dir output   # real API, writes locally; needs .env
python tools/reconcile_with_harlyy.py --start YYYY-MM-DD --end YYYY-MM-DD
```

## Rules

- **Never use AWS credentials or run AWS/Terraform commands against the account.** Give the user the
  command to run instead. No direct Redshift access either: write SQL for the user to run.
- The Harlyy API (`.env`: `HARLYY_CLIENT_SECRET`, `HARLYY_BUSINESS_ID`) may be called read-only for
  checks. Never commit `.env` (CI fails if it is tracked) and never print the secret.
- Glue runs **Python 3.9**: no `match`, no `X | Y` types, no 3.10+ stdlib. Extract/load use only stdlib +
  boto3 + pyarrow.
- Adding/changing a column: edit `TABLES`, regenerate `01_tables.sql` (and Athena views), and tell the user
  the `ALTER TABLE` to apply in Redshift **before** deploying, or the load fails with "Table definitions do
  not match". Update the data dictionary.
- Views: `CREATE OR REPLACE VIEW ... WITH NO SCHEMA BINDING`, every table schema-qualified. If the column
  list changes, `DROP VIEW IF EXISTS` first (CREATE OR REPLACE can't change columns).
- Times: tables store UTC (`*_at`); `*_local` and `*_date` are store-local (Lagos UTC+1, Nairobi UTC+3,
  no DST). Harlyy itself uses Lagos time for every store.
- Metrics must match Harlyy's rules (see the dictionary's metric table): Smile Score =
  `FLOOR(100 * SUM(smile_points) / SUM(smile_weight))`; incident counts use `is_survey_incident` only;
  customers = distinct per location per day, summed.
- Personal data: `submissions.customer_name/customer_phone`, `submission_answers.name/phone_number`.
- Harlyy API facts not obvious from code: list endpoints max `pageSize` 50; analytics at
  `/analytics/{submissions,incidents,reviews}?periodStart=ms&periodEnd=ms`; review `reply` has only
  `content` + `repliedAt` (no author); incident staff notes at `/incidents/{id}/comments` (one call per
  incident, loaded into `incident_comments`). Adding a note does **not** change the incident's
  `updatedAt`, hence the `COMMENTS_LOOKBACK_DAYS` re-read in `fetch()`.
- One-off Redshift changes that must precede a deploy go in `sql/redshift/migrations/`.
- CI (`.github/workflows/ci.yml`): ruff, pytest on 3.9 and 3.12, DDL diff, `terraform fmt -check` and
  `validate`. Run the Python checks before proposing a commit.
- Commit/push only when asked; branch off `main` and open a PR.
