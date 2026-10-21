"""Harlyy load (AWS Glue Python shell, Python 3.9).

Loads one extract run into Redshift Serverless through the Data API (IAM auth):

  1. read the run's manifest; a run with no new or changed submissions, incidents
     or reviews is skipped, so Redshift is not woken for nothing
  2. in parallel: check the target tables still have the columns the files were
     written with, and stage (empty each staging table, COPY its Parquet file in)
     as STAGE_GROUPS batches running side by side
  3. check staging in one query: row counts equal the manifest, no blank keys,
     no duplicates
  4. merge, in one transaction: tables with a key are upserted (MERGE on the key);
     child tables have every row of each parent in the run replaced. Any error rolls
     the whole run back and harlyy_feedback_analytics stays as it was. Rows written per table
     come from the transaction's own results, not from extra queries
  5. verify: none of the keys just loaded appears twice in the target tables

Cost: Redshift Serverless bills while statements run, so the load keeps that time
short. Staging runs in parallel, every check is a single query, and nothing scans a
whole target table: the merge and the verification only touch the keys in the run,
and child tables are sorted on their parent ID so their deletes stay cheap as
history grows.

Re-running a manifest gives the same result, so overlapping hours, retries and
backfills never create duplicates. Only one load runs at a time (the Glue job's
max concurrency is 1; the dispatcher Lambda waits and retries).

Job parameters (Glue passes them as --NAME value):
    --MANIFEST            required: s3:// URI of the run manifest (set by the dispatcher)
    --REDSHIFT_WORKGROUP  required: Redshift Serverless workgroup
    --REDSHIFT_DATABASE   required: existing database
    --REDSHIFT_SCHEMA     target schema (default: harlyy_feedback_analytics)
    --STAGING_SCHEMA      staging schema (default: harlyy_feedback_staging)
    --COPY_ROLE_ARN       IAM role Redshift uses to read S3 (default: the namespace's default role)
    --ALERTS_TOPIC_ARN    SNS topic for failures (emailed)
    --LOAD_QUEUE_URL      SQS load queue: a load that keeps hitting temporary Redshift
                          errors is re-queued here with a delay, up to MAX_ATTEMPTS
    --ATTEMPT             set by the dispatcher on re-queued loads (default 1)
"""

import argparse
import json
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor

TABLE_ORDER = ["submissions", "submission_answers", "incidents", "incident_metrics", "reviews",
               "locations", "location_labels", "labels", "surveys", "survey_steps", "step_options",
               "metrics", "staff"]
# Staging batches that run side by side, roughly balanced by size (answers are the
# largest table). Kept to a handful so the Data API's limit on active statements
# per workgroup is never reached.
STAGE_GROUPS = [["submission_answers"],
                ["submissions", "incidents", "incident_metrics"],
                ["reviews", "locations", "location_labels"],
                ["labels", "surveys", "survey_steps", "step_options", "metrics", "staff"]]
CHILDREN = {"submission_answers": ("submissions", "submission_id"), "incident_metrics": ("incidents", "incident_id"),
            "location_labels": ("locations", "location_id"), "step_options": ("survey_steps", "step_id")}
MAX_ATTEMPTS = 3
REQUEUE_DELAY_SECONDS = 600
RETRIES = 3
TRANSIENT = ["serializable isolation", "connection", "timeout", "throttl", "temporarily", "try again",
             "i/o error", "sending to the backend", "connection reset", "broken pipe", "unexpected eof",
             "resource busy", "insufficient capacity", "activestatementsexceeded", "active statements"]
IDENTIFIER = re.compile(r"^[a-z_][a-z0-9_]*$")


class Transient(Exception):
    """A Redshift error that is likely to pass if the load is tried again later."""


def is_transient(message):
    message = (message or "").lower()
    return any(t in message for t in TRANSIENT)


# ---------- SQL ----------------------------------------------------------------------------

def iam_role(role):
    return "default" if role in (None, "", "default") else f"'{role}'"


def stage_sql(manifest, staging, copy_role, names=None):
    """Empty each staging table and COPY this run's file in. Every staging table is
    emptied, including ones with no file this run, so stale rows are never reused.
    DELETE (not TRUNCATE) keeps each batch one transaction."""
    sql = []
    for name in names or TABLE_ORDER:
        sql.append(f"DELETE FROM {staging}.{name};")
        info = manifest["tables"].get(name)
        if info:
            sql.append(f"COPY {staging}.{name} FROM '{info['uri']}' IAM_ROLE {iam_role(copy_role)} FORMAT AS PARQUET;")
    return sql


def staging_checks_sql(manifest, staging):
    """One query: per table, staged rows, rows with a blank key, duplicate rows."""
    parts = []
    for name in TABLE_ORDER:
        info = manifest["tables"].get(name)
        if not info:
            continue
        unique = ", ".join(f"COALESCE({c}, '')" for c in info["unique"])
        blank = f"SUM(CASE WHEN {info['key']} IS NULL OR {info['key']} = '' THEN 1 ELSE 0 END)" if info["key"] else "0"
        distinct = (f"COUNT(DISTINCT {unique})" if len(info["unique"]) == 1 else
                    f"(SELECT COUNT(*) FROM (SELECT DISTINCT {unique} FROM {staging}.{name}))")
        parts.append(f"SELECT '{name}', COUNT(*), {blank}, COUNT(*) - {distinct} FROM {staging}.{name}")
    return " UNION ALL ".join(parts)


def merge_plan(manifest, schema, staging):
    """The merge transaction as [(table, action, sql)]. A child table's rows are replaced
    for every parent in the run, even when the child has no rows now (e.g. a submission
    whose answers were cleared)."""
    plan, tables = [], manifest["tables"]
    for name in TABLE_ORDER:
        info = tables.get(name)
        if info and info["key"]:
            cols, k = info["columns"], info["key"]
            target = f"{schema}.{name}"
            updates = ", ".join(f"{c} = s.{c}" for c in cols if c != k)
            plan.append((name, "merged", f"MERGE INTO {target} USING {staging}.{name} s ON {target}.{k} = s.{k} "
                         f"WHEN MATCHED THEN UPDATE SET {updates} "
                         f"WHEN NOT MATCHED THEN INSERT ({', '.join(cols)}) "
                         f"VALUES ({', '.join('s.' + c for c in cols)});"))
    # Children after every parent is merged. The delete is filtered on the parent ID,
    # which is the child table's sort key, so only the blocks for this run's parents are read.
    for name, (parent, col) in CHILDREN.items():
        if parent in tables:
            plan.append((name, "replaced", f"DELETE FROM {schema}.{name} USING {staging}.{parent} p "
                                           f"WHERE {schema}.{name}.{col} = p.{col};"))
            if name in tables:
                cols = ", ".join(tables[name]["columns"])
                plan.append((name, "inserted", f"INSERT INTO {schema}.{name} ({cols}) "
                                               f"SELECT {cols} FROM {staging}.{name};"))
    return plan


def merge_sql(manifest, schema, staging):
    return [sql for _, _, sql in merge_plan(manifest, schema, staging)]


def verify_sql(manifest, schema, staging):
    """One query: for each upserted table, keys from this run that now appear more than
    once in the target. Joined to staging, so it reads only this run's keys, not the
    whole history."""
    parts = []
    for name in TABLE_ORDER:
        info = manifest["tables"].get(name)
        if info and info["key"]:
            k = info["key"]
            parts.append(f"SELECT '{name}', COUNT(*) FROM (SELECT t.{k} FROM {schema}.{name} t "
                         f"JOIN {staging}.{name} s ON s.{k} = t.{k} GROUP BY t.{k} HAVING COUNT(*) > 1)")
    return " UNION ALL ".join(parts)


# ---------- Redshift Data API ---------------------------------------------------------------

class Redshift:
    def __init__(self, workgroup, database):
        import boto3

        # boto3 clients are thread-safe; one is shared by the parallel staging batches.
        self.client = boto3.client("redshift-data")
        self.workgroup, self.database = workgroup, database

    def _wait(self, statement_id, label):
        """Poll quickly at first (most statements finish in about a second), then back off."""
        delay = 0.25
        while True:
            desc = self.client.describe_statement(Id=statement_id)
            status = desc["Status"]
            if status == "FINISHED":
                return desc
            if status in ("FAILED", "ABORTED"):
                error = desc.get("Error") or status
                raise (Transient if is_transient(error) else RuntimeError)(f"{label}: {error}")
            time.sleep(delay)
            delay = min(delay * 2, 2)

    def _with_retries(self, label, step):
        for attempt in range(1, RETRIES + 1):
            try:
                return step()
            except Exception as err:
                # Data API throttling or a dropped connection surfaces as a boto error.
                if not isinstance(err, Transient) and not is_transient(str(err)):
                    raise
                if attempt == RETRIES:
                    raise Transient(str(err)) from err
                wait = 15 * 2 ** (attempt - 1)
                print(f"  {label}: temporary error, retrying in {wait}s ({err})")
                time.sleep(wait)

    def run(self, statements, label):
        """Run statements as one transaction, wait, and return rows affected per statement."""
        def step():
            response = self.client.batch_execute_statement(
                WorkgroupName=self.workgroup, Database=self.database, Sqls=statements,
                StatementName=label[:500])
            desc = self._wait(response["Id"], label)
            return [s.get("ResultRows", -1) for s in desc.get("SubStatements", [])]
        return self._with_retries(label, step)

    def query(self, sql, label):
        """Run one SELECT and return its rows as lists of Python values."""
        def step():
            response = self.client.execute_statement(
                WorkgroupName=self.workgroup, Database=self.database, Sql=sql, StatementName=label[:500])
            self._wait(response["Id"], label)
            rows, token = [], None
            while True:
                kwargs = {"Id": response["Id"]}
                if token:
                    kwargs["NextToken"] = token
                page = self.client.get_statement_result(**kwargs)
                rows += [[None if v.get("isNull") else next(iter(v.values())) for v in r] for r in page["Records"]]
                token = page.get("NextToken")
                if not token:
                    return rows
        return self._with_retries(label, step)


# ---------- load -----------------------------------------------------------------------------

def read_manifest(uri):
    import boto3

    if not uri.startswith("s3://"):
        raise SystemExit(f"--MANIFEST must be an s3:// URI, got {uri!r}")
    bucket, _, key = uri[len("s3://"):].partition("/")
    return json.loads(boto3.client("s3").get_object(Bucket=bucket, Key=key)["Body"].read())


def check_columns(redshift, manifest, schema, label):
    """The target tables must have exactly the columns, in order, that the files hold."""
    rows = redshift.query(f"SELECT table_name, column_name FROM svv_columns WHERE table_schema = '{schema}' "
                          f"ORDER BY table_name, ordinal_position", f"{label}-columns")
    actual = {}
    for table, column in rows:
        actual.setdefault(table, []).append(column)
    problems = [f"{schema}.{name}: Redshift has {actual.get(name)}, files have {info['columns']}"
                for name, info in manifest["tables"].items() if actual.get(name) != info["columns"]]
    if problems:
        raise RuntimeError("Table definitions do not match the extract; apply sql/redshift/01_tables.sql "
                           "changes first:\n  " + "\n  ".join(problems))


def load(args, manifest):
    schema, staging, run = args.REDSHIFT_SCHEMA, args.STAGING_SCHEMA, manifest["run"]
    label = f"harlyy-load-{run.replace('/', '-')}"
    redshift = Redshift(args.REDSHIFT_WORKGROUP, args.REDSHIFT_DATABASE)
    print(f"Loading {run} into {args.REDSHIFT_WORKGROUP}/{args.REDSHIFT_DATABASE}.{schema}")
    started = time.time()

    # 2. column check and staging, side by side. A missing file fails its COPY, so a
    # partial upload cannot load silently. Staging is only this job's, so the groups
    # do not need to be one transaction; the merge below is.
    with ThreadPoolExecutor(max_workers=len(STAGE_GROUPS) + 1) as pool:
        jobs = [pool.submit(check_columns, redshift, manifest, schema, label)]
        jobs += [pool.submit(redshift.run, stage_sql(manifest, staging, args.COPY_ROLE_ARN, group),
                             f"{label}-stage-{n}") for n, group in enumerate(STAGE_GROUPS, 1)]
        for job in jobs:
            job.result()  # re-raises the first failure
    print(f"  staged in {time.time() - started:.1f}s")

    # 3. staging checks, one query
    problems = []
    for name, staged, blank, dupes in redshift.query(staging_checks_sql(manifest, staging), f"{label}-checks"):
        staged, blank, dupes, expected = int(staged), int(blank or 0), int(dupes or 0), manifest["tables"][name]["rows"]
        if staged != expected:
            problems.append(f"{name}: staged {staged} rows, manifest says {expected}")
        if blank:
            problems.append(f"{name}: {blank} staged rows with a blank key")
        if dupes:
            problems.append(f"{name}: {dupes} duplicate staged rows")
    if problems:
        raise RuntimeError("Staging checks failed; nothing was merged:\n  " + "\n  ".join(problems))

    # 4. merge: one transaction, so a failure rolls the whole run back
    plan = merge_plan(manifest, schema, staging)
    affected = redshift.run([sql for _, _, sql in plan], f"{label}-merge")
    written = {}
    for (name, action, _), rows in zip(plan, affected):
        written.setdefault(name, {})[action] = rows
    for name, counts in written.items():
        print(f"  {name:20} " + ", ".join(f"{action} {rows}" for action, rows in counts.items()))

    # 5. verify, only for this run's keys
    dupes = {name: int(n) for name, n in redshift.query(verify_sql(manifest, schema, staging), f"{label}-verify")
             if int(n)}
    if dupes:
        raise RuntimeError(f"Duplicate keys found in {schema} after the merge: {dupes}")
    print(f"Loaded {run} in {time.time() - started:.1f}s")
    return written


def publish(topic_arn, status, message):
    print(json.dumps(message, default=str))
    if not topic_arn:
        return
    import boto3

    boto3.client("sns").publish(
        TopicArn=topic_arn, Subject=f"Harlyy load {status}: {message.get('run', '')}"[:99],
        Message=json.dumps(message, indent=2, default=str),
        MessageAttributes={"stage": {"DataType": "String", "StringValue": "load"},
                           "status": {"DataType": "String", "StringValue": status}})


def requeue(args, manifest):
    import boto3

    body = {"stage": "extract", "status": "success", "run": manifest["run"], "manifest": args.MANIFEST,
            "has_changes": True, "attempt": args.ATTEMPT + 1}
    boto3.client("sqs").send_message(QueueUrl=args.LOAD_QUEUE_URL, MessageBody=json.dumps(body),
                                     DelaySeconds=REQUEUE_DELAY_SECONDS)
    print(f"Re-queued for attempt {args.ATTEMPT + 1} of {MAX_ATTEMPTS} in {REQUEUE_DELAY_SECONDS // 60} minutes")


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--MANIFEST")
    p.add_argument("--REDSHIFT_WORKGROUP")
    p.add_argument("--REDSHIFT_DATABASE")
    p.add_argument("--REDSHIFT_SCHEMA", default="harlyy_feedback_analytics")
    p.add_argument("--STAGING_SCHEMA", default="harlyy_feedback_staging")
    p.add_argument("--COPY_ROLE_ARN", default="default")
    p.add_argument("--ALERTS_TOPIC_ARN")
    p.add_argument("--LOAD_QUEUE_URL")
    p.add_argument("--ATTEMPT", type=int, default=1)
    p.add_argument("--JOB_RUN_ID")
    args, _ = p.parse_known_args(argv)  # Glue adds arguments of its own
    for name in ("REDSHIFT_SCHEMA", "STAGING_SCHEMA"):
        if not IDENTIFIER.match(getattr(args, name)):
            p.error(f"--{name} must be a plain lowercase identifier")
    return args


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    missing = [n for n in ("MANIFEST", "REDSHIFT_WORKGROUP", "REDSHIFT_DATABASE") if not getattr(args, n)]
    if missing:
        raise SystemExit("Missing job parameters: " + ", ".join("--" + n for n in missing))

    manifest = read_manifest(args.MANIFEST)
    base = {"stage": "load", "run": manifest["run"], "manifest": args.MANIFEST, "attempt": args.ATTEMPT,
            "job_run_id": args.JOB_RUN_ID}
    if not manifest.get("has_changes", True):
        print(f"{manifest['run']}: no new or changed submissions, incidents or reviews; nothing to load")
        return
    try:
        written = load(args, manifest)
        print(json.dumps(dict(base, status="success", rows_written=written)))
    except Transient as err:
        if args.LOAD_QUEUE_URL and args.ATTEMPT < MAX_ATTEMPTS:
            requeue(args, manifest)
            return
        publish(args.ALERTS_TOPIC_ARN, "failed", dict(base, status="failed", error=str(err)[:1500]))
        raise
    except Exception as err:
        publish(args.ALERTS_TOPIC_ARN, "failed", dict(base, status="failed", error=str(err)[:1500]))
        raise


if __name__ == "__main__":
    main()
