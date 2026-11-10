"""Offline tests for the Glue scripts: transform, data quality, Parquet, run planning and load SQL."""

import importlib.util
import io
from datetime import datetime
from pathlib import Path

import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parent.parent


def _module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "glue" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


extract = _module("harlyy_extract")
load = _module("harlyy_load")
MS = 1792500000000  # 2026-10-20 UTC


def raw_fixture():
    location = {"id": "loc_1", "name": "DP OWERRI", "labels": ["lb_brand", "lb_region"],
                "address": {"country": "NG", "city": "Owerri"}, "coordinates": {"latitude": 5.4}, "updatedAt": MS}
    labels = [{"id": "lb_brand", "name": "Brand::Domino's"}, {"id": "lb_region", "name": "Region::South"}]
    rating = {"id": "step_rating", "survey": "sur_1", "type": "smileys", "status": "active", "position": 1,
              "title": "How was your overall experience?"}
    liked = {"id": "step_liked", "survey": "sur_1", "type": "metrics", "status": "active", "position": 2,
             "title": "What did you like?", "negativeTitle": "What can we improve?", "followUpStep": "step_rating",
             "metrics": {"metrics": ["mtr_food"], "multiSelect": True}}
    contact = {"id": "step_contact", "survey": "sur_1", "type": "contact", "status": "active", "position": 3}
    submission = {"id": "sbm_1", "survey": "sur_1", "location": "loc_1", "customer": "cus_1", "status": "completed",
                  "createdAt": MS, "updatedAt": MS + 60000, "steps": [
                      {"step": "step_rating", "submittedAt": MS + 1000, "rating": 2},
                      {"step": "step_liked", "submittedAt": MS + 2000, "metrics": ["mtr_food", "mtr_food"]},
                      {"step": "step_contact", "submittedAt": MS + 3000, "name": "Ada ", "phoneNumber": "+234800",
                       "text": "Cold pizza"}]}
    incident = {"id": "inc_1", "type": "submission", "status": "resolved", "submission": "sbm_1", "survey": "sur_1",
                "location": "loc_1", "rating": 2, "metrics": ["mtr_food"], "createdAt": MS, "updatedAt": MS,
                "resolvedAt": MS + 7200000}
    media = {"id": "inc_2", "type": "media-document", "status": "open", "mediaDocument": "md_1", "createdAt": MS}
    listing = {"id": "lst_1", "name": "Pastry Planet - Lagos - Saka", "coordinates": {"latitude": 6.5}}
    review = {"id": "rev_1", "listing": "lst_1", "directory": {"type": "chowdeck"}, "rating": 1,
              "reply": {"content": "Sorry", "repliedAt": MS}, "sentiment": {"sentiment": "negative"},
              "createdAt": MS, "updatedAt": MS}
    return {"submissions": [submission], "incidents": [incident, media], "reviews": [review],
            "locations": [location], "labels": labels, "metrics": [{"id": "mtr_food", "name": "Food Quality  "}],
            "staff": [{"id": "staff_1", "name": "Faith"}], "listings": [listing],
            "surveys": [{"id": "sur_1", "name": "Dominos - Dine-In Survey", "steps": ["step_rating", "step_liked"]}],
            "steps": {s["id"]: s for s in (rating, liked, contact)}}


def test_tables_pass_quality_checks_and_write_parquet():
    rows = extract.build_tables(raw_fixture())
    problems, _ = extract.check_quality(rows, raw_fixture())
    assert problems == []
    for table in extract.TABLES:
        assert rows[table["name"]], table["name"]
        parquet = pq.read_table(io.BytesIO(extract.to_parquet(table, rows[table["name"]])))
        assert parquet.column_names == extract.column_names(table)


def test_derived_values():
    rows = extract.build_tables(raw_fixture())
    sub = rows["submissions"][0]
    assert (sub["overall_rating"], sub["rating_band"], sub["customer_name"]) == (2, "negative", "Ada")
    rating = next(a for a in rows["submission_answers"] if a["answer_type"] == "rating")
    assert (rating["smile_weight"], rating["smile_points"]) == (2, 0.5)
    choices = [a for a in rows["submission_answers"] if a["answer_type"] == "choice"]
    assert len(choices) == 1  # the repeated option is kept once
    assert (choices[0]["question"], choices[0]["metric_sentiment"]) == ("What can we improve?", "improve")
    review = rows["reviews"][0]
    assert (review["brand"], review["country_code"], review["has_reply"]) == ("Pastry Planet", "NG", True)
    assert {i["is_survey_incident"] for i in rows["incidents"]} == {True, False}


def test_quality_catches_duplicates_blank_keys_and_orphans():
    rows = extract.build_tables(raw_fixture())
    rows["reviews"].append(dict(rows["reviews"][0]))
    rows["staff"].append(dict(rows["staff"][0], staff_id=None))
    rows["incident_metrics"].append({"incident_id": "inc_missing", "metric_id": "m", "metric_name": None})
    problems, _ = extract.check_quality(rows, raw_fixture())
    text = "\n".join(problems)
    assert "reviews: 1 duplicate" in text and "staff: 1 rows with no staff_id" in text
    assert "incident_metrics: 1 rows point to a incidents record" in text


def test_run_windows():
    args = extract.parse_args([])
    now = datetime(2026, 10, 21, 10, 30, tzinfo=extract.LAGOS)
    run, start, end, _ = extract.plan_run(args, now)
    assert run == "business_date=2026-10-21/hour=09"
    assert end - start == 70 * 60 * 1000  # one hour plus the 10-minute overlap
    run, start, end, _ = extract.plan_run(extract.parse_args(["--full-history", "true"]), now)
    assert (run, start) == ("full_history=2026-10-21T10", None)
    assert end == extract.ms(now.replace(minute=0))  # stops where the next hourly run starts
    assert extract.parse_reviews_from("2023").isoformat() == "2023-01-01"


def manifest(names):
    tables = {}
    for t in extract.TABLES:
        if t["name"] in names:
            tables[t["name"]] = {"uri": f"s3://b/harlyy/processed/{t['name']}/r/{t['name']}.parquet", "rows": 1,
                                 "columns": extract.column_names(t), "key": t["key"],
                                 "parent": list(t["parent"]) if t["parent"] else None, "unique": t["unique"]}
    return {"run": "business_date=2026-10-21/hour=09", "tables": tables, "has_changes": True}


def test_load_sql_covers_every_table_in_one_transaction():
    m = manifest({t["name"] for t in extract.TABLES})
    merge = load.merge_sql(m, "harlyy_feedback_analytics", "harlyy_feedback_staging")
    assert len(merge) <= 40  # Data API batch limit
    for t in extract.TABLES:
        assert any(f"harlyy_feedback_analytics.{t['name']} " in s for s in merge), t["name"]
    stage = load.stage_sql(m, "harlyy_feedback_staging", "arn:aws:iam::1:role/r")
    assert len(stage) <= 40 and sum(s.startswith("COPY") for s in stage) == len(extract.TABLES)
    assert load.TABLE_ORDER == [t["name"] for t in extract.TABLES]


def test_child_rows_replaced_even_without_child_file():
    m = manifest({"submissions"})
    merge = load.merge_sql(m, "s", "st")
    assert any(s.startswith("DELETE FROM s.submission_answers") for s in merge)
    assert not any("INSERT INTO s.submission_answers" in s for s in merge)
    stage = load.stage_sql(m, "st", "default")
    assert "DELETE FROM st.submission_answers;" in stage  # stale staging rows never reused


def test_staging_checks_and_transient_errors():
    sql = load.staging_checks_sql(manifest({"submissions", "submission_answers"}), "st")
    assert "COUNT(DISTINCT COALESCE(submission_id, ''))" in sql and "SELECT DISTINCT" in sql
    assert load.is_transient("ERROR: 1023 DETAIL: Serializable isolation violation")
    assert not load.is_transient("column \"x\" does not exist")


def test_parallel_staging_covers_every_table_once():
    grouped = [name for group in load.STAGE_GROUPS for name in group]
    assert sorted(grouped) == sorted(load.TABLE_ORDER) and len(grouped) == len(set(grouped))
    m = manifest({t["name"] for t in extract.TABLES})
    for group in load.STAGE_GROUPS:
        sql = load.stage_sql(m, "st", "default", group)
        assert len(sql) <= 40 and sum(s.startswith("DELETE") for s in sql) == len(group)


def test_merge_plan_labels_line_up_with_statements():
    m = manifest({t["name"] for t in extract.TABLES})
    plan = load.merge_plan(m, "s", "st")
    assert [sql for _, _, sql in plan] == load.merge_sql(m, "s", "st")
    actions = {(name, action) for name, action, _ in plan}
    assert ("submissions", "merged") in actions and ("submission_answers", "replaced") in actions
    assert ("submission_answers", "inserted") in actions


def test_verify_reads_only_this_runs_keys():
    sql = load.verify_sql(manifest({"submissions", "reviews"}), "s", "st")
    assert "JOIN st.submissions s ON s.submission_id = t.submission_id" in sql
    assert "JOIN st.reviews s ON s.review_id = t.review_id" in sql
    assert load.is_transient("ActiveStatementsExceededException: too many active statements")
    assert load.is_transient("An error occurred (ValidationException) when calling the ExecuteStatement "
                             "operation: Redshift endpoint is not available.")


def test_child_tables_sorted_on_parent_id():
    # Keeps the per-parent deletes in the merge cheap as history grows.
    for child, (_, col) in load.CHILDREN.items():
        table = next(t for t in extract.TABLES if t["name"] == child)
        assert table["sort"] == f"SORTKEY ({col})"


class FakeDataApi:
    """Stands in for boto3's redshift-data client: every statement succeeds, each DML
    statement reports 1 row, and the check queries return clean results."""

    def __init__(self, manifest):
        self.manifest, self.statements, self.batches = manifest, {}, []

    def batch_execute_statement(self, Sqls, **_):
        self.batches.append(Sqls)
        sid = f"b{len(self.statements)}"
        self.statements[sid] = {"Status": "FINISHED", "SubStatements": [{"ResultRows": 1} for _ in Sqls]}
        return {"Id": sid}

    def execute_statement(self, Sql, **_):
        sid = f"q{len(self.statements)}"
        if "svv_columns" in Sql:
            rows = [[name, col] for name, info in self.manifest["tables"].items() for col in info["columns"]]
        elif "HAVING COUNT(*) > 1" in Sql:
            rows = [[name, 0] for name, info in self.manifest["tables"].items() if info["key"]]
        else:  # staging checks
            rows = [[name, info["rows"], 0, 0] for name, info in self.manifest["tables"].items()]
        self.statements[sid] = {"Status": "FINISHED", "rows": rows}
        return {"Id": sid}

    def describe_statement(self, Id):
        return self.statements[Id]

    def get_statement_result(self, Id, **_):
        return {"Records": [[{"stringValue": v} if isinstance(v, str) else {"longValue": v} for v in row]
                             for row in self.statements[Id]["rows"]]}


def test_load_end_to_end_with_fake_redshift():
    m = manifest({t["name"] for t in extract.TABLES})
    fake = FakeDataApi(m)
    redshift = load.Redshift.__new__(load.Redshift)
    redshift.client, redshift.workgroup, redshift.database = fake, "wg", "db"
    original, load.Redshift = load.Redshift, lambda *_: redshift
    try:
        args = load.parse_args(["--MANIFEST", "s3://b/m.json", "--REDSHIFT_WORKGROUP", "wg", "--REDSHIFT_DATABASE", "db"])
        written = load.load(args, m)
    finally:
        load.Redshift = original
    assert len(fake.batches) == len(load.STAGE_GROUPS) + 1  # parallel staging + one merge transaction
    assert written["submissions"] == {"merged": 1}
    assert written["submission_answers"] == {"replaced": 1, "inserted": 1}


def test_ddl_has_target_and_staging_tables():
    text = extract.ddl()
    for t in extract.TABLES:
        assert f"harlyy_feedback_analytics.{t['name']} (" in text
        assert f"harlyy_feedback_staging.{t['name']} (LIKE harlyy_feedback_analytics.{t['name']})" in text


# ---------- Glue Data Catalog ----------------------------------------------------------------

class EntityNotFoundException(Exception):
    pass


class FakeGlue:
    """Stands in for boto3's glue client: keeps tables and partitions in memory."""

    def __init__(self):
        self.tables, self.partitions, self.calls = {}, {}, []

    def get_table(self, DatabaseName, Name):
        self.calls.append("get_table")
        if Name not in self.tables:
            raise EntityNotFoundException(Name)
        return {"Table": self.tables[Name]}

    def create_table(self, DatabaseName, TableInput):
        self.calls.append("create_table")
        self.tables[TableInput["Name"]] = TableInput

    def update_table(self, DatabaseName, TableInput):
        self.calls.append("update_table")
        self.tables[TableInput["Name"]] = TableInput

    def batch_create_partition(self, DatabaseName, TableName, PartitionInputList):
        errors = []
        for p in PartitionInputList:
            key = (TableName, tuple(p["Values"]))
            if key in self.partitions:
                errors.append({"PartitionValues": p["Values"], "ErrorDetail": {"ErrorCode": "AlreadyExistsException"}})
            else:
                self.partitions[key] = p["StorageDescriptor"]["Location"]
        return {"Errors": errors}


def test_partition_layout():
    assert extract.partition_of("business_date=2026-11-04/hour=09") == ("2026-11-04", "09")
    assert extract.partition_of("business_date=2026-11-04") == ("2026-11-04", "day")
    assert extract.partition_of("full_history=2026-10-22T08") == ("2026-10-22", "full")
    assert extract.partition_of("business_date=2026-11-04/hour=day") == ("2026-11-04", "day")
    storage = extract.Storage("b", "harlyy", local_dir="unused")
    # Hourly runs keep the folder they have always used.
    assert extract.processed_folder(storage, "submissions", "business_date=2026-11-04/hour=09") == \
        "harlyy/processed/submissions/business_date=2026-11-04/hour=09"
    assert extract.processed_folder(storage, "submissions", "business_date=2026-11-04").endswith(
        "business_date=2026-11-04/hour=day")


def test_catalog_columns_match_tables_and_never_clash_with_partitions():
    partition_names = {k["Name"] for k in extract.PARTITION_KEYS}
    for t in extract.TABLES:
        cols = extract.glue_columns(t)
        assert [c["Name"] for c in cols] == extract.column_names(t)
        assert not partition_names & set(extract.column_names(t)), t["name"]
    types = {c["Name"]: c["Type"] for c in extract.glue_columns(extract.TABLES[0])}
    assert (types["created_at"], types["created_date"], types["duration_ms"], types["is_completed"]) == \
        ("timestamp", "date", "bigint", "boolean")


def test_register_run_creates_once_and_ignores_existing_partitions(tmp_path):
    rows = extract.build_tables(raw_fixture())
    storage = extract.Storage("b", "harlyy", local_dir=tmp_path)
    run = "business_date=2026-11-04/hour=09"
    manifest = extract.write_processed(storage, run, rows)
    glue = FakeGlue()
    extract.register_run(extract.Catalog("lake", "s3://b/harlyy/processed", glue), storage, run, manifest)
    assert len(glue.tables) == len(extract.TABLES) == len(glue.partitions)
    location = glue.partitions[("submissions", ("2026-11-04", "09"))].replace("\\", "/")  # local test on Windows
    assert location.endswith("processed/submissions/business_date=2026-11-04/hour=09/")
    # The next run: tables unchanged, so no create or update (no new table versions).
    glue.calls.clear()
    extract.register_run(extract.Catalog("lake", "s3://b/harlyy/processed", glue), storage, run, manifest)
    assert "create_table" not in glue.calls and "update_table" not in glue.calls
    # A column added in code updates the table.
    glue.tables["staff"]["StorageDescriptor"]["Columns"] = glue.tables["staff"]["StorageDescriptor"]["Columns"][:-1]
    extract.Catalog("lake", "s3://b/harlyy/processed", glue).ensure_table(
        next(t for t in extract.TABLES if t["name"] == "staff"))
    assert glue.calls.count("update_table") == 1


def test_catalog_backfill_registers_existing_files_where_they_are(tmp_path):
    base = tmp_path / "harlyy" / "processed" / "submissions"
    for folder in ("business_date=2026-11-03/hour=22", "business_date=2026-11-04/hour=09",
                   "business_date=2026-11-04", "full_history=2026-10-22T08"):
        (base / folder).mkdir(parents=True, exist_ok=True)
        (base / folder / "submissions.parquet").write_bytes(b"x")
    (base / "notes.txt").write_bytes(b"x")
    storage = extract.Storage("b", "harlyy", local_dir=tmp_path)
    glue = FakeGlue()
    result = extract.backfill_catalog(storage, extract.Catalog("lake", storage.uri("harlyy/processed"), glue))
    parts = {values: loc for (_, values), loc in glue.partitions.items()}
    assert set(parts) == {("2026-11-03", "22"), ("2026-11-04", "09"), ("2026-11-04", "day"), ("2026-10-22", "full")}
    assert "full_history=2026-10-22T08" in parts[("2026-10-22", "full")]  # registered where it is
    # The old --date file is copied into hour=day, so it is not read on top of the hour folders.
    assert (base / "business_date=2026-11-04" / "hour=day" / "submissions.parquet").exists()
    assert len(result["copied"]) == 1 and len(result["skipped"]) == 1
    # Running it again adds nothing and copies nothing.
    again = extract.backfill_catalog(storage, extract.Catalog("lake", storage.uri("harlyy/processed"), glue))
    assert again["added"] == {"submissions": 0} and again["copied"] == []


def test_athena_views_file_is_up_to_date():
    text = (ROOT / "sql" / "athena" / "latest_views.sql").read_text(encoding="utf-8")
    assert text.splitlines() == (extract.athena_views() + "\n").splitlines()
    for t in extract.TABLES:
        assert f"VIEW harlyy_feedback_lake.latest_{t['name']} AS" in text
