"""Harlyy extract (AWS Glue Python shell, Python 3.9).

Harlyy API -> S3 raw (JSON) -> data quality checks -> S3 processed (Parquet) + manifest,
then a success message on the events topic, which starts harlyy_load.py through
SQS and the load dispatcher Lambda.

Default run: the last complete hour (Lagos time), starting OVERLAP_MINUTES early so a
record saved on the hour is never missed; the load MERGEs, so the overlap cannot
create duplicates. Records are picked up by updatedAt, so changes to older records
(an incident resolved, an abandoned survey completed) come through too.

Job parameters (Glue passes them as --NAME value):
    --S3_BUCKET            required: bucket for raw and processed files
    --S3_PREFIX            folder in the bucket (default: harlyy)
    --HARLYY_BUSINESS_ID   required: Harlyy business ID
    --HARLYY_SECRET_PARAM  required in AWS: SSM SecureString holding the Harlyy client secret
    --REVIEWS_FROM         reviews posted before this date are never loaded (default: 2026-01-01).
                           Keep it as a job default; hourly runs use it.
    --EVENTS_TOPIC_ARN     SNS topic that receives the success message (starts the load)
    --ALERTS_TOPIC_ARN     SNS topic that receives failures (emailed)
One-off runs (the next scheduled run is hourly again):
    --full-history true    everything changed before the start of the current hour
    --reviews-from DATE    reviews from this date or year (2023 / 2023-06-01) for this run only
    --hour YYYY-MM-DDTHH   one hour, e.g. a missed run
    --date YYYY-MM-DD      one whole day as a single run
    --from-raw true        rebuild Parquet from the run's raw files; no API calls

Local test: python glue/harlyy_extract.py --local-dir output --HARLYY_BUSINESS_ID ...
(the secret comes from HARLYY_CLIENT_SECRET or a .env file when not running in AWS).
"""

import argparse
import gzip
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

try:
    # Use the operating system's certificate store (offices that inspect HTTPS).
    import truststore

    truststore.inject_into_ssl()
except ImportError:
    pass

API_BASE = "https://api.harlyy.com"
PAGE_SIZE = 50  # API maximum
RETRIES = 3
OVERLAP_MINUTES = 10
DEFAULT_REVIEWS_FROM = "2026-01-01"

# Fixed offsets are safe: neither country uses daylight saving.
TIMEZONES = {"NG": ("Africa/Lagos", 1), "KE": ("Africa/Nairobi", 3)}
DEFAULT_COUNTRY = "NG"  # the business's own time zone
LAGOS = timezone(timedelta(hours=1))

# Location labels are "Group::Value"; each group becomes a locations column.
LABEL_COLUMNS = {"Brand": "brand", "Country": "country", "State": "state", "City": "city",
                 "Region": "region", "Regional Manager": "regional_manager", "Order Type": "order_type"}
BRANDS = {"domino": "Domino's", "cold stone": "Cold Stone Creamery", "pinkberry": "Pinkberry"}
CHANNELS = ("Dine-In", "Delivery", "Website")
NEGATIVE_MAX_RATING = 3  # ratings at or below this show a step's negativeTitle

# Harlyy's Smile Score for any group of smileys ratings:
#     FLOOR(100 * SUM(smile_points) / SUM(smile_weight))
# rating: (weight, points = weight x value), value 0, .25, .5, .75, 1 for 1-5 stars.
# Reverse-engineered from Harlyy's analytics: 757 of 782 scores match exactly; the rest
# are 1 point above Harlyy, on scores that land exactly on a whole number.
SMILE_WEIGHTS = {1: (20, 0), 2: (2, 0.5), 3: (2, 1), 4: (3, 2.25), 5: (3, 3)}


# ---------- tables -------------------------------------------------------------------
# Every table is defined once here: the Parquet files, the Redshift DDL and the
# manifest the load reads all come from these definitions.

REDSHIFT_TYPES = {"id": "VARCHAR(128)", "short": "VARCHAR(64)", "name": "VARCHAR(512)", "list": "VARCHAR(4096)",
                  "url": "VARCHAR(2048)", "text": "VARCHAR(65535)", "int": "INTEGER", "bigint": "BIGINT",
                  "float": "DOUBLE PRECISION", "bool": "BOOLEAN", "ts": "TIMESTAMP", "date": "DATE"}
MAX_TEXT_BYTES = {"id": 128, "short": 64, "name": 512, "list": 4096, "url": 2048, "text": 65535}


def _cols(spec):
    return [tuple(p.strip().split(":")) for p in spec.split(",") if p.strip()]


# name, columns, key (upsert) or None, parent (table, column) for child tables,
# unique: columns that identify a row (checked for duplicates), dist, sort
TABLES = [
    dict(name="submissions", columns=_cols("""
        submission_id:id, survey_id:id, location_id:id, customer_id:id, staff_id:id, device_id:id,
        status:short, is_completed:bool, alert_sent:bool,
        created_at:ts, updated_at:ts, last_answer_at:ts, created_at_local:ts, created_date:date,
        created_hour:int, weekday:short, duration_ms:bigint, duration_min:float,
        overall_rating:int, rating_band:short, has_comment:bool, comment_text:text,
        has_contact:bool, customer_name:name, customer_phone:short"""),
         key="submission_id", parent=None, unique=["submission_id"],
         dist="DISTKEY (submission_id)", sort="SORTKEY (created_date)"),
    dict(name="submission_answers", columns=_cols("""
        submission_id:id, step_id:id, step_type:short, question:text, metric_id:id, metric_name:name,
        answer:text, answer_type:short, submitted_at:ts, rating:int, text:text, name:name,
        phone_number:short, linked_rating:int, metric_sentiment:short, smile_weight:float, smile_points:float"""),
         key=None, parent=("submissions", "submission_id"), unique=["submission_id", "step_id", "metric_id"],
         dist="DISTKEY (submission_id)", sort="SORTKEY (submission_id)"),
    dict(name="incidents", columns=_cols("""
        incident_id:id, code:short, type:short, is_survey_incident:bool, status:short, is_open:bool,
        media_document_id:id, media_source_id:id, submission_id:id, survey_id:id, location_id:id,
        customer_id:id, staff_id:id, rating:int, assignee_ids:list, reviewed_by:id, resolved_by:id,
        created_at:ts, updated_at:ts, created_date:date, reviewed_at:ts, resolved_at:ts,
        hours_to_review:float, hours_to_resolve:float"""),
         key="incident_id", parent=None, unique=["incident_id"],
         # Not on submission_id: media-document incidents have none and would pile onto one slice.
         dist="DISTSTYLE EVEN", sort="SORTKEY (created_date)"),
    dict(name="incident_metrics", columns=_cols("incident_id:id, metric_id:id, metric_name:name"),
         key=None, parent=("incidents", "incident_id"), unique=["incident_id", "metric_id"],
         dist="DISTKEY (incident_id)", sort="SORTKEY (incident_id)"),
    # Google, Chowdeck and any other platform Harlyy collects from; the store listing's
    # details are copied onto each review.
    dict(name="reviews", columns=_cols("""
        review_id:id, source:short, listing_id:id, listing_name:name, brand:name, location_id:id,
        country_code:short, city:name, source_review_id:name, source_url:url, rating:int,
        title:name, content:text, customer_name:name, has_reply:bool, reply_content:text,
        replied_at:ts, sentiment:short, sentiment_positive:float, sentiment_negative:float,
        sentiment_neutral:float, status:short, review_created_at:ts, review_date:date,
        updated_at:ts, synced_at:ts, received_at:ts, alert_sent:bool"""),
         key="review_id", parent=None, unique=["review_id"], dist="DISTSTYLE EVEN", sort="SORTKEY (review_date)"),
    dict(name="locations", columns=_cols("""
        location_id:id, location_name:name, brand:name, country:name, state:name, city:name,
        region:name, regional_manager:name, order_type:name, other_labels:list, is_online:bool,
        timezone:short, country_code:short, address_line1:name, address_line2:name,
        city_address:name, postcode:short, latitude:float, longitude:float,
        google_place_id:name, status:short, updated_at:ts"""),
         key="location_id", parent=None, unique=["location_id"], dist="DISTSTYLE ALL", sort="SORTKEY (location_id)"),
    dict(name="location_labels", columns=_cols("location_id:id, label_id:id"),
         key=None, parent=("locations", "location_id"), unique=["location_id", "label_id"],
         dist="DISTSTYLE ALL", sort="SORTKEY (location_id)"),
    dict(name="labels", columns=_cols("""
        label_id:id, label_name:name, label_group:name, label_value:name, type:short, description:text, status:short"""),
         key="label_id", parent=None, unique=["label_id"], dist="DISTSTYLE ALL", sort="SORTKEY (label_id)"),
    dict(name="surveys", columns=_cols("""
        survey_id:id, survey_name:name, brand:name, channel:short, survey_type:short, status:short,
        step_count:int, created_at:ts"""),
         key="survey_id", parent=None, unique=["survey_id"], dist="DISTSTYLE ALL", sort="SORTKEY (survey_id)"),
    dict(name="survey_steps", columns=_cols("""
        step_id:id, survey_id:id, position:int, step_type:short, question:text,
        negative_question:text, description:text, follow_up_step_id:id, is_multi_select:bool,
        status:short, is_archived:bool, is_overall_rating:bool"""),
         key="step_id", parent=None, unique=["step_id"], dist="DISTSTYLE ALL", sort="SORTKEY (step_id)"),
    dict(name="step_options", columns=_cols("step_id:id, metric_id:id, metric_name:name, option_order:int"),
         key=None, parent=("survey_steps", "step_id"), unique=["step_id", "metric_id"],
         dist="DISTSTYLE ALL", sort="SORTKEY (step_id)"),
    dict(name="metrics", columns=_cols("""
        metric_id:id, metric_name:name, description:text, hide_from_analytics:bool, status:short"""),
         key="metric_id", parent=None, unique=["metric_id"], dist="DISTSTYLE ALL", sort="SORTKEY (metric_id)"),
    dict(name="staff", columns=_cols("staff_id:id, name:name, position:name, status:short, last_active_at:ts"),
         key="staff_id", parent=None, unique=["staff_id"], dist="DISTSTYLE ALL", sort="SORTKEY (staff_id)"),
]
FACT_TABLES = ("submissions", "submission_answers", "incidents", "incident_metrics", "reviews")


def column_names(table):
    return [name for name, _ in table["columns"]]


def ddl(schema="harlyy_feedback_analytics", staging_schema="harlyy_feedback_staging"):
    """CREATE statements for the target tables and their staging copies."""
    out = [f"CREATE SCHEMA IF NOT EXISTS {schema};", f"CREATE SCHEMA IF NOT EXISTS {staging_schema};", ""]
    # No column ENCODE: Redshift then chooses and adjusts compression itself (table ENCODE AUTO).
    for t in TABLES:
        cols = ",\n".join(f"    {n} {REDSHIFT_TYPES[c]}" for n, c in t["columns"])
        key = f",\n    PRIMARY KEY ({t['key']})" if t["key"] else ""
        out.append(f"CREATE TABLE IF NOT EXISTS {schema}.{t['name']} (\n{cols}{key}\n)\n{t['dist']}\n{t['sort']};\n")
    out.append("-- Staging: the load job's own working copies, emptied at the start of every load.")
    for t in TABLES:
        out.append(f"CREATE TABLE IF NOT EXISTS {staging_schema}.{t['name']} (LIKE {schema}.{t['name']});")
    return "\n".join(out) + "\n"


# ---------- Harlyy API ------------------------------------------------------------------

class Harlyy:
    def __init__(self, business_id, token, recorder):
        self.base = f"{API_BASE}/v2/businesses/{business_id}"
        self.token = token
        self.recorder = recorder
        self.requests = 0

    def _get_json(self, url):
        """GET a JSON document, retrying dropped connections and server errors."""
        req = urllib.request.Request(url, headers={"Accept": "application/json",
                                                   "Authorization": f"Bearer {self.token}"})
        for attempt in range(1, RETRIES + 1):
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    self.requests += 1
                    return json.loads(resp.read() or b"null")
            except urllib.error.HTTPError as e:
                if e.code not in (429, 500, 502, 503, 504) or attempt == RETRIES:
                    detail = e.read().decode(errors="replace")[:500]
                    raise RuntimeError(f"GET {url.split('?')[0]} failed with HTTP {e.code}: {detail}") from None
            except OSError as e:  # connection reset, timeout, DNS
                if attempt == RETRIES:
                    raise RuntimeError(f"GET {url.split('?')[0]} failed: {e}") from e
            time.sleep(2 ** attempt)

    def get(self, path, entity):
        record = self._get_json(self.base + path)["data"]
        self.recorder.add(entity, [record])
        return record

    def list(self, path, entity, filters=()):
        """Every record of a list endpoint. Keyed by ID, so a record pushed onto the
        next page by new arrivals mid-run is kept once."""
        items, page = {}, 0
        while True:
            params = [("page", page), ("pageSize", PAGE_SIZE),
                      ("sorts", json.dumps({"field": "createdAt", "order": "desc"}))]
            params += [("filters", json.dumps(f)) for f in filters]
            batch = self._get_json(f"{self.base}{path}?{urllib.parse.urlencode(params)}")["data"]
            self.recorder.add(entity, batch)
            items.update((item["id"], item) for item in batch)
            if len(batch) < PAGE_SIZE:
                print(f"  {path}: {len(items)} records")
                return list(items.values())
            page += 1


def updated_between(start_ms, end_ms):
    filters = [{"field": "updatedAt", "type": "lt", "value": end_ms}]
    if start_ms is not None:
        filters.insert(0, {"field": "updatedAt", "type": "gte", "value": start_ms})
    return filters


def fetch(api, filters, reviews_from_ms):
    """Records changed in the window, plus every lookup they refer to."""
    raw = {
        "submissions": api.list("/submissions", "submissions", filters),
        "incidents": api.list("/incidents", "incidents", filters),
        "reviews": api.list("/reviews", "reviews",
                            list(filters) + [{"field": "createdAt", "type": "gte", "value": reviews_from_ms}]),
        # Lookups are small; taken whole every run.
        "locations": api.list("/locations", "locations"),
        "labels": api.list("/labels", "labels"),
        "metrics": api.list("/metrics", "metrics"),
        "staff": api.list("/staff", "staff"),
        "listings": api.list("/listings", "listings"),
    }
    # Listing surveys needs a staff login, but single surveys can be fetched:
    # refresh every survey the run refers to.
    survey_ids = sorted({r["survey"] for r in raw["submissions"] + raw["incidents"] if r.get("survey")})
    raw["surveys"] = [api.get(f"/surveys/{sid}", "surveys") for sid in survey_ids]
    steps = {}
    for survey in raw["surveys"]:
        order = {step_id: n for n, step_id in enumerate(survey.get("steps") or [], 1)}
        for step in api.list(f"/surveys/{survey['id']}/steps", "steps"):
            step["position"] = order.get(step["id"])
            steps[step["id"]] = step
    # The steps list leaves out archived steps that older submissions still answer.
    missing = {(s["survey"], a["step"]) for s in raw["submissions"] for a in s.get("steps") or []
               if a["step"] not in steps}
    for survey_id, step_id in sorted(missing):
        steps[step_id] = api.get(f"/surveys/{survey_id}/steps/{step_id}", "steps")
    raw["steps"] = steps
    return raw


# ---------- transform ----------------------------------------------------------------------

def utc(ms):
    """Epoch ms -> naive UTC datetime (stored as TIMESTAMP)."""
    return datetime.fromtimestamp(ms / 1000, timezone.utc).replace(tzinfo=None) if ms else None


def local(ms, country):
    offset = TIMEZONES.get(country, TIMEZONES[DEFAULT_COUNTRY])[1]
    return utc(ms) + timedelta(hours=offset) if ms else None


def hours_between(start_ms, end_ms):
    return round((end_ms - start_ms) / 3_600_000, 2) if start_ms and end_ms else None


def joined(values):
    return ";".join(values) if values else None


def clean(text):
    """Collapse runs of whitespace; Harlyy option names carry trailing spaces."""
    return " ".join(text.split()) if text else text


def survey_brand(name):
    lower = (name or "").lower()
    return next((brand for key, brand in BRANDS.items() if key in lower), None)


def listing_brand(name):
    """Known brand, else the part of the listing name before ' - '."""
    return survey_brand(name) or ((name or "").split(" - ")[0].strip() or None)


def survey_channel(name):
    lower = (name or "").lower()
    return next((c for c in CHANNELS if c.lower() in lower), None)


def rating_band(rating):
    if rating is None:
        return None
    return "negative" if rating <= 2 else "neutral" if rating == 3 else "positive"


def country_from_coordinates(coords):
    """Chowdeck listings have no address. Nigeria lies north of the equator, the
    Kenyan stores (Nairobi, Mombasa) south of it."""
    latitude = (coords or {}).get("latitude")
    if latitude is None:
        return None
    return "NG" if latitude > 0 else "KE"


def build_tables(raw):
    steps = raw["steps"]
    labels = {lb["id"]: lb for lb in raw["labels"]}
    metric_name = {m["id"]: clean(m.get("name")) for m in raw["metrics"]}
    listings = {lst["id"]: lst for lst in raw["listings"]}
    t = {}

    t["locations"] = []
    for loc in raw["locations"]:
        values = dict.fromkeys(LABEL_COLUMNS.values())
        other = []
        for label_id in loc.get("labels") or []:
            name = (labels.get(label_id) or {}).get("name") or ""
            group, _, value = name.partition("::")
            if value and group in LABEL_COLUMNS:
                values[LABEL_COLUMNS[group]] = value.strip()
            elif name:
                other.append(name)
        address = loc.get("address") or {}
        coords = loc.get("coordinates") or {}
        country_code = address.get("country") or values["country"] or DEFAULT_COUNTRY
        t["locations"].append({
            "location_id": loc["id"], "location_name": loc.get("name"), **values, "other_labels": joined(other),
            "is_online": bool(values["order_type"]) or (loc.get("name") or "").lower().startswith("online"),
            "timezone": TIMEZONES.get(country_code, TIMEZONES[DEFAULT_COUNTRY])[0], "country_code": country_code,
            "address_line1": address.get("line1"), "address_line2": address.get("line2"),
            "city_address": address.get("city"), "postcode": address.get("postcode"),
            "latitude": coords.get("latitude"), "longitude": coords.get("longitude"),
            "google_place_id": loc.get("googlePlaceId"), "status": loc.get("status"),
            "updated_at": utc(loc.get("updatedAt")),
        })
    country_of = {r["location_id"]: r["country_code"] for r in t["locations"]}

    t["location_labels"] = [{"location_id": loc["id"], "label_id": lid}
                            for loc in raw["locations"] for lid in dict.fromkeys(loc.get("labels") or [])]

    t["labels"] = []
    for lb in raw["labels"]:
        group, _, value = (lb.get("name") or "").partition("::")
        t["labels"].append({"label_id": lb["id"], "label_name": lb.get("name"),
                            "label_group": group.strip() if value else None, "label_value": value.strip() or None,
                            "type": lb.get("type"), "description": lb.get("description"), "status": lb.get("status")})

    t["metrics"] = [{"metric_id": m["id"], "metric_name": metric_name[m["id"]], "description": m.get("description"),
                     "hide_from_analytics": m.get("hideFromAnalytics"), "status": m.get("status")}
                    for m in raw["metrics"]]

    t["staff"] = [{"staff_id": s["id"], "name": s.get("name"), "position": s.get("position"),
                   "status": s.get("status"), "last_active_at": utc(s.get("lastActiveAt"))} for s in raw["staff"]]

    t["surveys"] = [{"survey_id": s["id"], "survey_name": s.get("name"), "brand": survey_brand(s.get("name")),
                     "channel": survey_channel(s.get("name")), "survey_type": s.get("type"), "status": s.get("status"),
                     "step_count": len(s.get("steps") or []), "created_at": utc(s.get("createdAt"))}
                    for s in raw["surveys"]]

    # The survey's main 1-5 question: its first active smileys step.
    overall_step = {}
    for step in sorted(steps.values(), key=lambda st: st.get("position") or 999):
        if step.get("type") == "smileys" and step.get("status") == "active":
            overall_step.setdefault(step.get("survey"), step["id"])

    t["survey_steps"] = [{
        "step_id": st["id"], "survey_id": st.get("survey"), "position": st.get("position"), "step_type": st.get("type"),
        "question": st.get("title"), "negative_question": st.get("negativeTitle"), "description": st.get("description"),
        "follow_up_step_id": st.get("followUpStep"), "is_multi_select": (st.get("metrics") or {}).get("multiSelect"),
        "status": st.get("status"), "is_archived": st.get("status") == "archived",
        "is_overall_rating": st["id"] in overall_step.values(),
    } for st in steps.values()]

    t["step_options"] = [{"step_id": st["id"], "metric_id": mid, "metric_name": metric_name.get(mid), "option_order": n}
                         for st in steps.values()
                         for n, mid in enumerate(dict.fromkeys((st.get("metrics") or {}).get("metrics") or []), 1)]

    t["submissions"], t["submission_answers"] = [], []
    for s in raw["submissions"]:
        country = country_of.get(s.get("location")) or DEFAULT_COUNTRY
        answers = s.get("steps") or []
        ratings = {a["step"]: a["rating"] for a in answers if a.get("rating") is not None}
        overall = ratings.get(overall_step.get(s.get("survey")))
        texts = [a["text"].strip() for a in answers if (a.get("text") or "").strip()]
        contact = next((a for a in answers if a.get("phoneNumber") or a.get("name")), {})
        times = [a["submittedAt"] for a in answers if a.get("submittedAt")]
        created = local(s["createdAt"], country)
        duration = s["updatedAt"] - s["createdAt"] if s.get("updatedAt") else None
        t["submissions"].append({
            "submission_id": s["id"], "survey_id": s.get("survey"), "location_id": s.get("location"),
            "customer_id": s.get("customer"), "staff_id": s.get("staff"), "device_id": s.get("device"),
            "status": s.get("status"), "is_completed": s.get("status") == "completed", "alert_sent": s.get("alertSent"),
            "created_at": utc(s["createdAt"]), "updated_at": utc(s.get("updatedAt")),
            "last_answer_at": utc(max(times)) if times else None,
            "created_at_local": created, "created_date": created.date(),
            "created_hour": created.hour, "weekday": created.strftime("%a"),
            # Harlyy's analytics avgTime is the mean of updatedAt - createdAt.
            "duration_ms": duration, "duration_min": round(duration / 60000, 2) if duration is not None else None,
            "overall_rating": overall, "rating_band": rating_band(overall),
            # Harlyy counts any text answer as a comment, contact-step text included.
            "has_comment": bool(texts), "comment_text": " | ".join(texts) or None,
            "has_contact": bool(contact), "customer_name": (contact.get("name") or "").strip() or None,
            "customer_phone": contact.get("phoneNumber"),
        })
        seen = set()
        for a in answers:
            if not (a.get("rating") is not None or a.get("text") or a.get("name") or a.get("phoneNumber")
                    or a.get("metrics")):
                continue  # screen viewed, nothing answered
            step = steps.get(a["step"]) or {}
            # A metrics step asks "what did you like" or "what can we improve" depending
            # on the answer to its follow-up rating step.
            linked = ratings.get(step.get("followUpStep"))
            negative = bool(step.get("negativeTitle")) and linked is not None and linked <= NEGATIVE_MAX_RATING
            base = {
                "submission_id": s["id"], "step_id": a["step"], "step_type": step.get("type"),
                "question": step.get("negativeTitle") if negative else step.get("title"),
                "metric_id": None, "metric_name": None, "answer": None, "answer_type": None,
                "submitted_at": utc(a.get("submittedAt")), "rating": a.get("rating"), "text": a.get("text"),
                "name": a.get("name"), "phone_number": a.get("phoneNumber"), "linked_rating": linked,
                "metric_sentiment": ("improve" if negative else "liked")
                                    if step.get("negativeTitle") and linked is not None else None,
                "smile_weight": None, "smile_points": None,
            }
            if step.get("type") == "smileys" and a.get("rating") in SMILE_WEIGHTS:
                base["smile_weight"], base["smile_points"] = SMILE_WEIGHTS[a["rating"]]
            rows = []
            if a.get("metrics"):
                rows = [dict(base, metric_id=mid, metric_name=metric_name.get(mid), answer=metric_name.get(mid),
                             answer_type="choice") for mid in dict.fromkeys(a["metrics"])]
            elif a.get("rating") is not None:
                rows = [dict(base, answer=str(a["rating"]), answer_type="rating")]
            elif a.get("name") or a.get("phoneNumber"):
                rows = [dict(base, answer=(a.get("name") or "").strip() or a.get("phoneNumber"), answer_type="contact")]
            else:
                rows = [dict(base, answer=a["text"].strip() or None, answer_type="text")]
            for row in rows:
                ident = (row["step_id"], row["metric_id"])
                if ident not in seen:  # a step answered twice in one submission: keep the first
                    seen.add(ident)
                    t["submission_answers"].append(row)

    t["incidents"], t["incident_metrics"] = [], []
    for inc in raw["incidents"]:
        t["incidents"].append({
            "incident_id": inc["id"], "code": inc.get("code"), "type": inc.get("type"),
            "is_survey_incident": inc.get("type") == "submission",
            "status": inc.get("status"), "is_open": inc.get("status") != "resolved",
            # media-document incidents point here instead of at a submission; the API
            # has no endpoint to look these IDs up yet.
            "media_document_id": inc.get("mediaDocument"), "media_source_id": inc.get("mediaSource"),
            "submission_id": inc.get("submission"), "survey_id": inc.get("survey"),
            "location_id": inc.get("location"), "customer_id": inc.get("customer"), "staff_id": inc.get("staff"),
            "rating": inc.get("rating"), "assignee_ids": joined(inc.get("assignees")),
            "reviewed_by": inc.get("reviewedBy"), "resolved_by": inc.get("resolvedBy"),
            "created_at": utc(inc["createdAt"]), "updated_at": utc(inc.get("updatedAt")),
            "created_date": local(inc["createdAt"], country_of.get(inc.get("location"))).date(),
            "reviewed_at": utc(inc.get("reviewedAt")), "resolved_at": utc(inc.get("resolvedAt")),
            "hours_to_review": hours_between(inc["createdAt"], inc.get("reviewedAt")),
            "hours_to_resolve": hours_between(inc["createdAt"], inc.get("resolvedAt")),
        })
        t["incident_metrics"] += [{"incident_id": inc["id"], "metric_id": mid, "metric_name": metric_name.get(mid)}
                                  for mid in dict.fromkeys(inc.get("metrics") or [])]

    t["reviews"] = []
    for rev in raw["reviews"]:
        directory = rev.get("directory") or {}
        reply = rev.get("reply") or {}
        sentiment = rev.get("sentiment") or {}
        scores = sentiment.get("confidenceScore") or {}
        listing = listings.get(rev.get("listing")) or {}
        address = listing.get("address") or {}
        country_code = address.get("country") or country_from_coordinates(listing.get("coordinates"))
        t["reviews"].append({
            "review_id": rev["id"], "source": directory.get("type"), "listing_id": rev.get("listing"),
            "listing_name": listing.get("name"), "brand": listing_brand(listing.get("name")),
            "location_id": listing.get("location"), "country_code": country_code, "city": address.get("city"),
            "source_review_id": directory.get("resourceId"), "source_url": directory.get("url"),
            "rating": rev.get("rating"), "title": rev.get("subject"), "content": rev.get("content"),
            "customer_name": rev.get("customerName"),
            "has_reply": bool(reply.get("content")), "reply_content": reply.get("content"),
            "replied_at": utc(reply.get("repliedAt")),
            "sentiment": sentiment.get("sentiment"), "sentiment_positive": scores.get("positive"),
            "sentiment_negative": scores.get("negative"), "sentiment_neutral": scores.get("neutral"),
            "status": rev.get("status"), "review_created_at": utc(rev.get("createdAt")),
            "review_date": local(rev["createdAt"], country_code or DEFAULT_COUNTRY).date()
                           if rev.get("createdAt") else None,
            "updated_at": utc(rev.get("updatedAt")), "synced_at": utc(directory.get("syncedAt")),
            "received_at": utc(rev.get("receivedAt")), "alert_sent": rev.get("alertSent"),
        })
    return t


# ---------- data quality -------------------------------------------------------------------

def check_quality(rows, raw):
    """Hard problems stop the run (processed files are not uploaded); warnings are printed."""
    problems, warnings = [], []
    for t in TABLES:
        data, cols = rows[t["name"]], column_names(t)
        for row in data[:1]:
            if list(row) != cols:
                problems.append(f"{t['name']}: columns {sorted(set(row) ^ set(cols)) or 'order'} differ from the table definition")
        if t["key"]:
            blank = sum(1 for r in data if not r[t["key"]])
            if blank:
                problems.append(f"{t['name']}: {blank} rows with no {t['key']}")
        idents = [tuple(r[c] for c in t["unique"]) for r in data]
        dupes = len(idents) - len(set(idents))
        if dupes:
            problems.append(f"{t['name']}: {dupes} duplicate rows on ({', '.join(t['unique'])})")
        for name, code in t["columns"]:
            limit = MAX_TEXT_BYTES.get(code)
            if limit:
                long_rows = sum(1 for r in data if r[name] and len(str(r[name]).encode("utf-8")) > limit)
                if long_rows:
                    problems.append(f"{t['name']}.{name}: {long_rows} values longer than {REDSHIFT_TYPES[code]}")
        if t["parent"]:
            parent, col = t["parent"]
            parent_ids = {r[col] for r in rows[parent]}
            orphans = sum(1 for r in data if r[col] not in parent_ids)
            if orphans:
                problems.append(f"{t['name']}: {orphans} rows point to a {parent} record not in this run")

    location_ids = {r["location_id"] for r in rows["locations"]}
    unknown = sum(1 for r in rows["submissions"] if r["location_id"] and r["location_id"] not in location_ids)
    if unknown:
        warnings.append(f"submissions: {unknown} rows for locations not in the location list")
    listing_ids = {lst["id"] for lst in raw["listings"]}
    unknown = sum(1 for r in rows["reviews"] if r["listing_id"] and r["listing_id"] not in listing_ids)
    if unknown:
        warnings.append(f"reviews: {unknown} rows for listings not in the listing list")
    unknown = sum(1 for r in rows["submission_answers"] if not r["step_type"])
    if unknown:
        warnings.append(f"submission_answers: {unknown} answers to steps Harlyy no longer returns")
    return problems, warnings


# ---------- storage ------------------------------------------------------------------------

RAW_ENTITIES = ("submissions", "incidents", "reviews", "locations", "labels", "metrics", "staff",
                "listings", "surveys", "steps")


class Recorder:
    """Keeps every record the API returned, so raw can be saved even when a run fails."""

    def __init__(self):
        self.records = {e: {} for e in RAW_ENTITIES}

    def add(self, entity, records):
        self.records[entity].update((r["id"], r) for r in records)


class Storage:
    """Run files on S3, or under a local folder for tests:
        <prefix>/raw/<entity>/<run>/<entity>.jsonl.gz
        <prefix>/processed/<table>/<run>/<table>.parquet
        <prefix>/manifests/<run>.json
    Re-running a run overwrites its own files and nothing else."""

    def __init__(self, bucket, prefix, local_dir=None):
        self.bucket, self.prefix = bucket, prefix
        self.local_dir = Path(local_dir) if local_dir else None
        self.s3 = None
        if not self.local_dir:
            import boto3

            self.s3 = boto3.client("s3")

    def uri(self, key):
        return str(self.local_dir / key) if self.local_dir else f"s3://{self.bucket}/{key}"

    def put(self, key, body):
        if self.local_dir:
            path = self.local_dir / key
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(body)
        else:
            self.s3.put_object(Bucket=self.bucket, Key=key, Body=body)
        return self.uri(key)

    def get(self, key):
        if self.local_dir:
            return (self.local_dir / key).read_bytes()
        return self.s3.get_object(Bucket=self.bucket, Key=key)["Body"].read()

    def write_raw(self, run, recorder):
        for entity, records in recorder.records.items():
            lines = "\n".join(json.dumps(r, ensure_ascii=False) for r in records.values())
            self.put(f"{self.prefix}/raw/{entity}/{run}/{entity}.jsonl.gz", gzip.compress(lines.encode("utf-8")))

    def read_raw(self, run):
        raw = {}
        for entity in RAW_ENTITIES:
            text = gzip.decompress(self.get(f"{self.prefix}/raw/{entity}/{run}/{entity}.jsonl.gz")).decode("utf-8")
            raw[entity] = [json.loads(line) for line in text.splitlines() if line]
        raw["steps"] = {step["id"]: step for step in raw["steps"]}
        return raw


def to_parquet(table, rows):
    import pyarrow as pa
    import pyarrow.parquet as pq

    types = {"int": pa.int32(), "bigint": pa.int64(), "float": pa.float64(), "bool": pa.bool_(),
             "ts": pa.timestamp("us"), "date": pa.date32()}
    arrays = [pa.array([r[n] for r in rows], type=types.get(c, pa.string())) for n, c in table["columns"]]
    buffer = io.BytesIO()
    pq.write_table(pa.Table.from_arrays(arrays, names=column_names(table)), buffer, compression="snappy")
    return buffer.getvalue()


def write_processed(storage, run, rows):
    """Parquet for every non-empty table, then the manifest the load reads."""
    tables = {}
    for t in TABLES:
        data = rows[t["name"]]
        if not data:
            continue
        uri = storage.put(f"{storage.prefix}/processed/{t['name']}/{run}/{t['name']}.parquet", to_parquet(t, data))
        tables[t["name"]] = {"uri": uri, "rows": len(data), "columns": column_names(t), "key": t["key"],
                             "parent": list(t["parent"]) if t["parent"] else None, "unique": t["unique"]}
    manifest = {"run": run, "written_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "tables": tables, "has_changes": any(n in tables for n in FACT_TABLES)}
    manifest["uri"] = storage.put(f"{storage.prefix}/manifests/{run}.json", json.dumps(manifest, indent=2).encode())
    return manifest


# ---------- run ----------------------------------------------------------------------------

def true_or_false(value):
    if str(value).strip().lower() in ("true", "1", "yes"):
        return True
    if str(value).strip().lower() in ("false", "0", "no", ""):
        return False
    raise argparse.ArgumentTypeError(f"expected true or false, got {value!r}")


def parse_reviews_from(value):
    """'2023' -> 2023-01-01; '2023-06-01' -> that date."""
    value = str(value).strip()
    if re.fullmatch(r"\d{4}", value):
        return date(int(value), 1, 1)
    return date.fromisoformat(value)


def ms(dt):
    return int(dt.timestamp() * 1000)


def plan_run(args, now=None):
    """(run label, start ms or None, end ms, description) for this run."""
    now = now or datetime.now(LAGOS)
    this_hour = now.astimezone(LAGOS).replace(minute=0, second=0, microsecond=0)
    if args.full_history:
        return (f"full_history={this_hour:%Y-%m-%dT%H}", None, ms(this_hour),
                f"FULL HISTORY: everything changed before {this_hour:%Y-%m-%d %H:00} Lagos")
    if args.date:
        day = datetime.combine(date.fromisoformat(args.date), datetime.min.time(), tzinfo=LAGOS)
        return (f"business_date={day:%Y-%m-%d}", ms(day), ms(day + timedelta(days=1)),
                f"day {day:%Y-%m-%d} (Lagos)")
    hour = (datetime.strptime(args.hour, "%Y-%m-%dT%H").replace(tzinfo=LAGOS) if args.hour
            else this_hour - timedelta(hours=1))
    return (f"business_date={hour:%Y-%m-%d}/hour={hour:%H}", ms(hour - timedelta(minutes=OVERLAP_MINUTES)),
            ms(hour + timedelta(hours=1)), f"hour {hour:%Y-%m-%d %H}:00-{hour + timedelta(hours=1):%H}:00 Lagos")


def load_env_file():
    """Local runs only: read KEY=VALUE lines from a .env file next to the repo."""
    for path in (Path.cwd() / ".env", Path(__file__).resolve().parent.parent / ".env"):
        if path.exists():
            for line in path.read_text(encoding="utf-8").splitlines():
                if "=" in line and not line.strip().startswith("#"):
                    key, value = line.split("=", 1)
                    os.environ.setdefault(key.strip(), value.strip().strip("'\""))
            return


def api_token(args):
    if os.environ.get("HARLYY_CLIENT_SECRET"):
        return os.environ["HARLYY_CLIENT_SECRET"]
    if not args.HARLYY_SECRET_PARAM:
        raise SystemExit("Set --HARLYY_SECRET_PARAM (or HARLYY_CLIENT_SECRET for a local run)")
    import boto3

    response = boto3.client("ssm").get_parameter(Name=args.HARLYY_SECRET_PARAM, WithDecryption=True)
    return response["Parameter"]["Value"]


def publish(topic_arn, status, message):
    """Success goes to the events topic (starts the load); failures to the alerts topic (emailed)."""
    print(json.dumps(message, default=str))
    if not topic_arn:
        return
    import boto3

    boto3.client("sns").publish(
        TopicArn=topic_arn, Subject=f"Harlyy extract {status}: {message.get('run', '')}"[:99],
        Message=json.dumps(message, indent=2, default=str),
        MessageAttributes={"stage": {"DataType": "String", "StringValue": "extract"},
                           "status": {"DataType": "String", "StringValue": status}})


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--S3_BUCKET")
    p.add_argument("--S3_PREFIX", default="harlyy")
    p.add_argument("--HARLYY_BUSINESS_ID")
    p.add_argument("--HARLYY_SECRET_PARAM")
    p.add_argument("--REVIEWS_FROM", default=DEFAULT_REVIEWS_FROM)
    p.add_argument("--EVENTS_TOPIC_ARN")
    p.add_argument("--ALERTS_TOPIC_ARN")
    p.add_argument("--JOB_RUN_ID")  # passed by Glue; included in messages
    p.add_argument("--full-history", dest="full_history", nargs="?", const="true", default="false", type=true_or_false)
    p.add_argument("--reviews-from", dest="reviews_from")
    p.add_argument("--hour", help="YYYY-MM-DDTHH (Lagos)")
    p.add_argument("--date", help="YYYY-MM-DD (Lagos), the whole day as one run")
    p.add_argument("--from-raw", dest="from_raw", nargs="?", const="true", default="false", type=true_or_false)
    p.add_argument("--local-dir", dest="local_dir", help="local test: write here instead of S3, publish nothing")
    p.add_argument("--print-ddl", dest="print_ddl", action="store_true", help="print the Redshift DDL and exit")
    args, _ = p.parse_known_args(argv)  # Glue adds arguments of its own
    if args.S3_BUCKET:
        args.S3_BUCKET = args.S3_BUCKET.strip().replace("s3://", "").strip("/")
    args.S3_PREFIX = args.S3_PREFIX.strip().strip("/")
    if sum(bool(x) for x in (args.full_history, args.hour, args.date)) > 1:
        p.error("use only one of --full-history, --hour, --date")
    return args


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.print_ddl:
        print(ddl())
        return
    if args.local_dir:
        load_env_file()
        args.HARLYY_BUSINESS_ID = args.HARLYY_BUSINESS_ID or os.environ.get("HARLYY_BUSINESS_ID")
        args.EVENTS_TOPIC_ARN = args.ALERTS_TOPIC_ARN = None
    elif not args.S3_BUCKET:
        raise SystemExit("--S3_BUCKET is required (or --local-dir for a local test)")

    run, start_ms, end_ms, description = plan_run(args)
    job_default = parse_reviews_from(args.REVIEWS_FROM)
    reviews_from = parse_reviews_from(args.reviews_from) if args.reviews_from else job_default
    if reviews_from < job_default:
        print(f"warning: --reviews-from {reviews_from} is earlier than the job's REVIEWS_FROM {job_default}. "
              f"Hourly runs will not keep reviews before {job_default} up to date; change REVIEWS_FROM on the job "
              f"(Terraform) to {reviews_from} as well.")
    print(f"Run {run}: {description}; reviews posted from {reviews_from}")

    storage = Storage(args.S3_BUCKET, args.S3_PREFIX, args.local_dir)
    base_message = {"stage": "extract", "run": run, "job_run_id": args.JOB_RUN_ID}
    try:
        if args.from_raw:
            print("Rebuilding from raw files (no API calls)")
            raw = storage.read_raw(run)
        else:
            if not args.HARLYY_BUSINESS_ID:
                raise SystemExit("--HARLYY_BUSINESS_ID is required")
            recorder = Recorder()
            api = Harlyy(args.HARLYY_BUSINESS_ID, api_token(args), recorder)
            reviews_from_ms = ms(datetime.combine(reviews_from, datetime.min.time(), tzinfo=LAGOS))
            try:
                raw = fetch(api, updated_between(start_ms, end_ms), reviews_from_ms)
            finally:
                # Raw is kept even when the pull fails: that is when it is needed to investigate.
                storage.write_raw(run, recorder)
                print(f"Raw: {api.requests} API responses saved")

        rows = build_tables(raw)
        problems, warnings = check_quality(rows, raw)
        for w in warnings:
            print(f"warning: {w}")
        counts = {name: len(r) for name, r in rows.items()}
        print("Rows: " + ", ".join(f"{k} {v}" for k, v in counts.items()))
        if problems:
            publish(args.ALERTS_TOPIC_ARN, "failed", dict(base_message, status="failed", problems=problems,
                                                          rows=counts, note="processed files were not uploaded"))
            raise SystemExit("Data quality problems:\n  - " + "\n  - ".join(problems))

        manifest = write_processed(storage, run, rows)
        print(f"Data quality checks passed; manifest {manifest['uri']}")
        publish(args.EVENTS_TOPIC_ARN, "success", dict(base_message, status="success", manifest=manifest["uri"],
                                                       has_changes=manifest["has_changes"], rows=counts))
    except SystemExit:
        raise
    except Exception as err:
        publish(args.ALERTS_TOPIC_ARN, "failed", dict(base_message, status="failed", error=str(err)[:1500]))
        raise


if __name__ == "__main__":
    main()
