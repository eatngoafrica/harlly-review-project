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
    sentences = [{"offset": 0, "length": 9, "sentiment": "negative", "categories": ["rcat_wait", "rcat_wait"],
                  "confidenceScore": {"positive": 0.1, "negative": 0.8, "neutral": 0.1}},
                 {"offset": 10, "length": 5, "sentiment": "neutral", "categories": []}]
    review = {"id": "rev_1", "listing": "lst_1", "directory": {"type": "chowdeck"}, "rating": 1,
              "reply": {"content": "Sorry", "repliedAt": MS},
              "sentiment": {"sentiment": "negative", "sentences": sentences}, "createdAt": MS, "updatedAt": MS}
    brands = [{"id": "brand_kfc", "name": "KFC Kenya"}, {"id": "brand_other", "name": "Somewhere Else"}]
    competitor_listings = [
        {"id": "clst_1", "name": "KFC Westlands", "brand": "brand_kfc", "formattedAddress": "Nairobi, Kenya",
         "directory": {"type": "google", "resourceId": "place_1"}, "active": True, "createdAt": MS},
        {"id": "clst_2", "name": "Other Place", "brand": "brand_other", "formattedAddress": "Lagos, Nigeria"}]
    competitor_reviews = [
        {"id": "crev_1", "competitorListing": "clst_1", "directory": {"type": "google"}, "rating": 2,
         "customerName": "Someone", "sentiment": {"sentiment": "negative", "sentences": sentences[:1]},
         "createdAt": MS, "updatedAt": MS},
        {"id": "crev_2", "competitorListing": "clst_2", "rating": 5, "createdAt": MS, "updatedAt": MS}]
    return {"submissions": [submission], "incidents": [incident, media], "reviews": [review],
            "competitor_reviews": competitor_reviews, "competitor_listings": competitor_listings, "brands": brands,
            "review_categories": [{"id": "rcat_wait", "name": "Wait Time", "type": "Customer Service"}],
            "competitor_listing_ratings": [{"id": "clst_1", "rating": 4.25,
                                            "ratingsToDate": {"four": 3, "five": 1}}],
            "locations": [location], "labels": labels, "metrics": [{"id": "mtr_food", "name": "Food Quality  "}],
            "staff": [{"id": "staff_1", "name": "Faith"}], "listings": [listing],
            "surveys": [{"id": "sur_1", "name": "Dominos - Dine-In Survey", "steps": ["step_rating", "step_liked"]}],
            "steps": {s["id"]: s for s in (rating, liked, contact)},
            "incident_comments": [{"id": "cmt_1", "type": "incident", "source": "inc_1", "staff": "staff_1",
                                   "content": "Called the customer", "attachments": [],
                                   "metadata": {"resolveWithComment": "true"}, "createdAt": MS, "updatedAt": MS}]}


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
    note = rows["incident_comments"][0]
    assert (note["incident_id"], note["staff_id"], note["is_resolution_note"], note["attachment_count"]) == \
        ("inc_1", "staff_1", True, 0)


def test_topics_and_competitors():
    rows = extract.build_tables(raw_fixture())
    # One row per sentence per topic; a topic repeated on a sentence counts once, untagged sentences none.
    assert [(r["review_id"], r["sentence_no"], r["topic"], r["topic_group"], r["sentiment"])
            for r in rows["review_topics"]] == [("rev_1", 1, "Wait Time", "Customer Service", "negative")]
    # Only brands in COMPETITOR_BRANDS are kept, with their reviews; reviewer names are not loaded.
    assert [r["brand_name"] for r in rows["brands"]] == ["KFC Kenya"]
    assert [(r["competitor_listing_id"], r["country_code"]) for r in rows["competitor_listings"]] == [("clst_1", "KE")]
    review = rows["competitor_reviews"][0]
    assert len(rows["competitor_reviews"]) == 1 and "customer_name" not in review
    assert (review["brand"], review["review_date"].isoformat()) == ("KFC Kenya", "2026-10-20")
    assert [r["competitor_review_id"] for r in rows["competitor_review_topics"]] == ["crev_1"]
    # Competitor branches' all-time stars come from Harlyy's analytics.
    assert (rows["competitor_listings"][0]["google_rating"], rows["competitor_listings"][0]["google_review_count"]) == \
        (4.25, 4)


def test_counts_in_harlyy_follows_harlyys_incident_rule():
    cutoff = extract.HARLYY_COUNTS_ALL_ACTIONABLE_FROM_MS
    media = {"type": "media-document", "actionable": True}
    assert extract.counts_in_harlyy({"type": "submission"}) and extract.counts_in_harlyy({"type": "review"})
    assert extract.counts_in_harlyy(dict(media, createdAt=cutoff))
    assert not extract.counts_in_harlyy(dict(media, createdAt=cutoff - 1))          # before: only if picked up
    assert extract.counts_in_harlyy(dict(media, createdAt=cutoff - 1, reviewedAt=cutoff))
    assert not extract.counts_in_harlyy(dict(media, actionable=False, createdAt=cutoff))


class FakeHarlyy:
    """Stands in for the Harlyy client in fetch(): list endpoints filtered on createdAt
    / updatedAt, and comments per incident."""

    def __init__(self, incidents, comments):
        self.incidents, self._comments, self.recorder = incidents, comments, extract.Recorder()
        self.comment_calls = []

    def list(self, path, entity, filters=()):
        records = self.incidents if path == "/incidents" else []
        for f in filters:
            op = {"gte": lambda a, b: a >= b, "lt": lambda a, b: a < b}[f["type"]]
            records = [r for r in records if r.get(f["field"]) is not None and op(r[f["field"]], f["value"])]
        self.recorder.add(entity, records)
        return list(records)

    def get(self, path, entity):
        raise AssertionError(path)

    def analytics(self, kind, entity, list_key, id_key):
        return []

    def comments(self, incident_id):
        self.comment_calls.append(incident_id)
        return self._comments.get(incident_id, [])


def test_hourly_run_picks_up_comments_added_to_unchanged_recent_incidents():
    hour = 3_600_000
    start, end = MS, MS + hour
    changed = {"id": "inc_changed", "createdAt": MS - 5 * 86_400_000, "updatedAt": MS + 60_000}
    quiet = {"id": "inc_quiet", "createdAt": MS - 2 * 86_400_000, "updatedAt": MS - 2 * 86_400_000}
    noted = {"id": "inc_noted", "createdAt": MS - 3 * 86_400_000, "updatedAt": MS - 3 * 86_400_000}
    old = {"id": "inc_old", "createdAt": MS - 40 * 86_400_000, "updatedAt": MS - 40 * 86_400_000}
    comments = {"inc_noted": [{"id": "c1", "source": "inc_noted", "createdAt": MS + 120_000}],
                "inc_quiet": [{"id": "c2", "source": "inc_quiet", "createdAt": MS - 86_400_000}],
                "inc_old": [{"id": "c3", "source": "inc_old", "createdAt": MS + 60_000}]}
    api = FakeHarlyy([changed, quiet, noted, old], comments)
    raw = extract.fetch(api, extract.updated_between(start, end), None, start, end)
    # changed: in the window; noted: a comment added this hour; quiet: nothing new;
    # old: outside the lookback (its comment waits until the incident itself changes)
    assert sorted(i["id"] for i in raw["incidents"]) == ["inc_changed", "inc_noted"]
    assert [c["id"] for c in raw["incident_comments"]] == ["c1"]
    assert "inc_old" not in api.comment_calls
    # Full history: every incident and its comments, no lookback needed.
    api = FakeHarlyy([changed, quiet, noted, old], comments)
    raw = extract.fetch(api, extract.updated_between(None, end), None, None, end)
    assert len(raw["incidents"]) == 4 and len(raw["incident_comments"]) == 3


def test_from_raw_refuses_runs_saved_before_comments(tmp_path):
    storage = extract.Storage("b", "harlyy", local_dir=tmp_path)
    run = "business_date=2026-11-04/hour=09"
    for entity in extract.RAW_ENTITIES:
        if entity != "incident_comments":
            storage.put(f"harlyy/raw/{entity}/{run}/{entity}.jsonl.gz", extract.gzip.compress(b""))
    try:
        storage.read_raw(run)
    except SystemExit as err:
        assert "--from-raw" in str(err)
    else:
        raise AssertionError("expected SystemExit")


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
    # Catch-up: everything changed from a day to the start of this hour (stored like a full history).
    run, start, end, _ = extract.plan_run(extract.parse_args(["--since", "2026-09-01"]), now)
    assert run == "since=2026-09-01/to=2026-10-21T10"
    assert start == extract.ms(datetime(2026, 9, 1, tzinfo=extract.LAGOS)) and end == extract.ms(now.replace(minute=0))
    assert extract.partition_of(run) == ("2026-10-21", "full")
    assert extract.rerun_hint(run) == "Glue job, Run with parameters: --since 2026-09-01"


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
    # Staging runs one STAGE_GROUPS batch at a time; each must fit the Data API batch limit.
    stage = [load.stage_sql(m, "harlyy_feedback_staging", "arn:aws:iam::1:role/r", g) for g in load.STAGE_GROUPS]
    assert max(len(batch) for batch in stage) <= 40
    assert sum(s.startswith("COPY") for batch in stage for s in batch) == len(extract.TABLES)
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
    assert "COUNT(DISTINCT COALESCE(CAST(submission_id AS VARCHAR), ''))" in sql and "SELECT DISTINCT" in sql
    # Identifying columns that are numbers are compared as text (Redshift rejects COALESCE(int, '')).
    sql = load.staging_checks_sql(manifest({"review_topics"}), "st")
    assert "COALESCE(CAST(sentence_no AS VARCHAR), '')" in sql
    numeric = {n for t in extract.TABLES for n, c in t["columns"] if c in ("int", "bigint", "float", "bool", "ts", "date")}
    every = load.staging_checks_sql(manifest({t["name"] for t in extract.TABLES}), "st")
    assert not any(f"COALESCE({n}, '')" in every for n in numeric)
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


def test_rate_limits_pause_every_thread_and_retry(monkeypatch):
    import email.message
    import urllib.error

    def refusal(retry_after=None):
        headers = email.message.Message()
        if retry_after:
            headers["Retry-After"] = retry_after
        return urllib.error.HTTPError("u", 429, "Too Many Requests", headers,
                                      io.BytesIO(b'{"errors":[{"code":"too-many-requests"}]}'))

    class Answer(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    replies = [refusal("7"), refusal(), Answer(b'{"data": [1]}')]

    def urlopen(req, timeout):
        reply = replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply

    clock = {"now": 1000.0}
    slept = []
    monkeypatch.setattr(extract.urllib.request, "urlopen", urlopen)
    monkeypatch.setattr(extract.time, "time", lambda: clock["now"])
    monkeypatch.setattr(extract.time, "sleep", lambda s: (slept.append(s), clock.update(now=clock["now"] + s)))
    api = extract.Harlyy("bus_1", "token", extract.Recorder())
    assert api._get_json("https://x/y") == {"data": [1]}
    assert slept == [7, 10]  # Harlyy's Retry-After, then the backoff for the 2nd refusal

    replies[:] = [refusal() for _ in range(extract.RATE_LIMIT_RETRIES)]
    try:
        api._get_json("https://x/y")
        raise AssertionError("should give up")
    except RuntimeError as err:
        assert "HTTP 429" in str(err) and not replies
