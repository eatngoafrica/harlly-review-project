"""Export survey submissions from the Harlyy API to JSON files.

Docs: https://docs.harlyy.com (see /api/surveys, /api/submissions, /querying)

Configuration is read from a .env file next to this script (never commit it):
    HARLYY_BUSINESS_ID=     your business ID
    HARLYY_CLIENT_SECRET=   used directly as the Bearer token
    HARLYY_ACCESS_TOKEN=    optional, used instead of the client secret
    HARLYY_SURVEY_IDS=      optional, comma-separated survey IDs

Usage:
    python harlyy_export.py                 # all surveys, all submissions
    python harlyy_export.py --since 2026-10-01
    python harlyy_export.py --survey SURVEY_ID --survey OTHER_ID
    python harlyy_export.py --analytics --since 2026-10-01 --until 2026-10-19
    python harlyy_export.py --tables        # flat CSV tables in output/tables
"""

import argparse
import csv
import json
import os 
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

API_BASE = "https://api.harlyy.com"
PAGE_SIZE = 50  # API maximum


def load_env(path):
    """Minimal .env loader: KEY=VALUE lines, # comments, optional quotes."""
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip("'\""))


def http_json(method, url, token=None, body=None):
    headers = {"Accept": "application/json"}
    data = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:500]
        sys.exit(f"{method} {url} failed with HTTP {e.code}: {detail}")


def get_access_token():
    # The API accepts the client secret directly as a Bearer token, so no
    # /oauth/token exchange (or client ID) is needed.
    token = os.environ.get("HARLYY_ACCESS_TOKEN") or os.environ.get("HARLYY_CLIENT_SECRET")
    if not token:
        sys.exit("Set HARLYY_CLIENT_SECRET (or HARLYY_ACCESS_TOKEN) in .env")
    return token


def to_millis(day, end_of_day=False):
    """YYYY-MM-DD (UTC) -> epoch milliseconds, as the API expects."""
    dt = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    if end_of_day:
        dt += timedelta(days=1) - timedelta(milliseconds=1)
    return int(dt.timestamp() * 1000)


def extract_items(payload):
    """Pull the list of objects out of a list response.

    The docs don't publish the ListResponse schema, so accept a bare list or
    the common wrapper keys.
    """
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ("data", "items", "results", "docs"):
            if isinstance(payload.get(key), list):
                return payload[key]
    sys.exit(f"Unrecognised list response shape: {json.dumps(payload)[:500]}")


def fetch_all(path, token, filters=()):
    """Page through a list endpoint until a short page is returned."""
    items, page = [], 0
    while True:
        params = [
            ("page", page),
            ("pageSize", PAGE_SIZE),
            ("sorts", json.dumps({"field": "createdAt", "order": "desc"})),
        ]
        params += [("filters", json.dumps(f)) for f in filters]
        url = f"{API_BASE}{path}?{urllib.parse.urlencode(params)}"
        batch = extract_items(http_json("GET", url, token))
        items.extend(batch)
        if len(batch) < PAGE_SIZE:
            return items
        page += 1


def ms_to_iso(ms):
    if ms is None:
        return None
    return datetime.fromtimestamp(ms / 1000, timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def joined(values):
    return ";".join(values) if values else None


def write_csv(path, columns, rows):
    # utf-8-sig so Excel shows names with accents and emoji correctly.
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)
    print(f"{path.name}: {len(rows)} rows")


def analytics_rows(analytics, date):
    """Flatten one analytics block into rows: the total, then each survey and location."""
    def row(level, item_id, name, a, labels=None):
        ratings = a.get("ratings") or {}
        return {"date": date, "level": level, "id": item_id, "name": name, "label_ids": joined(labels),
                "submissions": a.get("submissions"), "customers": a.get("customers"),
                "comments": a.get("comments"), "incidents": a.get("incidents"),
                "rating_1": ratings.get("one"), "rating_2": ratings.get("two"), "rating_3": ratings.get("three"),
                "rating_4": ratings.get("four"), "rating_5": ratings.get("five"),
                "smile_score": a.get("smileScore"), "avg_time_ms": a.get("avgTime")}
    rows = [row("total", None, "All", analytics)]
    rows += [row("survey", s.get("survey"), s.get("name"), s) for s in analytics.get("surveys") or []]
    rows += [row("location", loc.get("location"), loc.get("name"), loc, loc.get("labels"))
             for loc in analytics.get("locations") or []]
    return rows


def export_tables(business, token, out_dir, filters, survey_ids):
    """Write flat CSV tables for loading into a database and aggregating there."""
    base = f"/v2/businesses/{business}"
    out_dir.mkdir(parents=True, exist_ok=True)

    submissions = list({s["id"]: s for s in fetch_all(f"{base}/submissions", token, filters)}.values())
    incidents = list({i["id"]: i for i in fetch_all(f"{base}/incidents", token, filters)}.values())
    locations = fetch_all(f"{base}/locations", token)
    labels = fetch_all(f"{base}/labels", token)
    metrics = fetch_all(f"{base}/metrics", token)

    # Listing surveys needs a staff token, but single surveys can be fetched,
    # so take the IDs from the submissions.
    survey_ids = sorted(set(survey_ids) | {s["survey"] for s in submissions if s.get("survey")})
    surveys = [http_json("GET", f"{API_BASE}{base}/surveys/{sid}", token)["data"] for sid in survey_ids]
    steps = {}
    for survey in surveys:
        order = {step_id: n for n, step_id in enumerate(survey.get("steps") or [], 1)}
        for step in fetch_all(f"{base}/surveys/{survey['id']}/steps", token):
            step["position"] = order.get(step["id"])
            steps[step["id"]] = step
    # The steps list leaves out archived steps that old submissions still answer.
    missing = {(s["survey"], a["step"]) for s in submissions for a in s.get("steps") or [] if a["step"] not in steps}
    for survey_id, step_id in sorted(missing):
        steps[step_id] = http_json("GET", f"{API_BASE}{base}/surveys/{survey_id}/steps/{step_id}", token)["data"]

    write_csv(out_dir / "surveys.csv", ["survey_id", "name", "type", "status", "step_count", "created_at"], [
        {"survey_id": s["id"], "name": s.get("name"), "type": s.get("type"), "status": s.get("status"),
         "step_count": len(s.get("steps") or []), "created_at": ms_to_iso(s.get("createdAt"))}
        for s in surveys])

    write_csv(out_dir / "survey_steps.csv",
              ["step_id", "survey_id", "position", "type", "title", "negative_title", "description",
               "follow_up_step_id", "metric_ids", "status"], [
        {"step_id": st["id"], "survey_id": st.get("survey"), "position": st.get("position"),
         "type": st.get("type"), "title": st.get("title"), "negative_title": st.get("negativeTitle"),
         "description": st.get("description"), "follow_up_step_id": st.get("followUpStep"),
         "metric_ids": joined((st.get("metrics") or {}).get("metrics")), "status": st.get("status")}
        for st in steps.values()])

    write_csv(out_dir / "locations.csv",
              ["location_id", "name", "address_line1", "address_line2", "city", "country", "postcode",
               "latitude", "longitude", "google_place_id", "status"], [
        {"location_id": loc["id"], "name": loc.get("name"),
         "address_line1": (loc.get("address") or {}).get("line1"),
         "address_line2": (loc.get("address") or {}).get("line2"),
         "city": (loc.get("address") or {}).get("city"), "country": (loc.get("address") or {}).get("country"),
         "postcode": (loc.get("address") or {}).get("postcode"),
         "latitude": (loc.get("coordinates") or {}).get("latitude"),
         "longitude": (loc.get("coordinates") or {}).get("longitude"),
         "google_place_id": loc.get("googlePlaceId"), "status": loc.get("status")}
        for loc in locations])

    write_csv(out_dir / "location_labels.csv", ["location_id", "label_id"], [
        {"location_id": loc["id"], "label_id": label_id}
        for loc in locations for label_id in loc.get("labels") or []])

    write_csv(out_dir / "labels.csv", ["label_id", "type", "name", "description", "status"], [
        {"label_id": lb["id"], "type": lb.get("type"), "name": lb.get("name"),
         "description": lb.get("description"), "status": lb.get("status")}
        for lb in labels])

    write_csv(out_dir / "metrics.csv", ["metric_id", "name", "description", "hide_from_analytics", "status"], [
        {"metric_id": m["id"], "name": m.get("name"), "description": m.get("description"),
         "hide_from_analytics": m.get("hideFromAnalytics"), "status": m.get("status")}
        for m in metrics])

    sub_rows, answer_rows = [], []
    for s in submissions:
        answers = s.get("steps") or []
        ratings = {a["step"]: a["rating"] for a in answers if a.get("rating") is not None}
        contact = next((a for a in answers if a.get("phoneNumber") or a.get("name")), {})
        times = [a["submittedAt"] for a in answers if a.get("submittedAt")]
        sub_rows.append({
            "submission_id": s["id"], "created_at": ms_to_iso(s.get("createdAt")),
            "updated_at": ms_to_iso(s.get("updatedAt")),
            "last_answer_at": ms_to_iso(max(times)) if times else None,
            # Harlyy's analytics avgTime is the mean of updatedAt - createdAt.
            "duration_ms": s["updatedAt"] - s["createdAt"] if s.get("updatedAt") else None,
            "survey_id": s.get("survey"), "location_id": s.get("location"), "customer_id": s.get("customer"),
            "staff_id": s.get("staff"), "device_id": s.get("device"), "order_id": s.get("order"),
            "status": s.get("status"), "alert_sent": s.get("alertSent"), "force_incident": s.get("forceIncident"),
            # Some surveys ask more than one rating; submission_answers has them all.
            "first_rating": next(iter(ratings.values()), None),
            "customer_name": (contact.get("name") or "").strip() or None,
            "customer_phone": contact.get("phoneNumber"),
        })
        for a in answers:
            step = steps.get(a["step"], {})
            row = {"submission_id": s["id"], "step_id": a["step"], "step_type": step.get("type"),
                   "submitted_at": ms_to_iso(a.get("submittedAt")), "rating": a.get("rating"),
                   "text": a.get("text"), "name": a.get("name"), "phone_number": a.get("phoneNumber"),
                   "metric_id": None,
                   # A metrics step asks "what did you like" or "what can we improve"
                   # depending on the answer to its follow-up rating step.
                   "linked_rating": ratings.get(step.get("followUpStep"))}
            if a.get("metrics"):
                answer_rows.extend(dict(row, metric_id=m) for m in a["metrics"])
            else:
                answer_rows.append(row)

    write_csv(out_dir / "submissions.csv", list(sub_rows[0]) if sub_rows else ["submission_id"], sub_rows)
    write_csv(out_dir / "submission_answers.csv",
              ["submission_id", "step_id", "step_type", "submitted_at", "rating", "text", "name",
               "phone_number", "metric_id", "linked_rating"], answer_rows)

    write_csv(out_dir / "incidents.csv",
              ["incident_id", "code", "created_at", "type", "status", "submission_id", "survey_id", "location_id",
               "customer_id", "staff_id", "rating", "metric_ids", "label_ids", "assignee_ids",
               "reviewed_by", "reviewed_at", "resolved_by", "resolved_at"], [
        {"incident_id": i["id"], "code": i.get("code"), "created_at": ms_to_iso(i.get("createdAt")),
         "type": i.get("type"), "status": i.get("status"), "submission_id": i.get("submission"),
         "survey_id": i.get("survey"), "location_id": i.get("location"), "customer_id": i.get("customer"),
         "staff_id": i.get("staff"), "rating": i.get("rating"), "metric_ids": joined(i.get("metrics")),
         "label_ids": joined(i.get("labels")), "assignee_ids": joined(i.get("assignees")),
         "reviewed_by": i.get("reviewedBy"), "reviewed_at": ms_to_iso(i.get("reviewedAt")),
         "resolved_by": i.get("resolvedBy"), "resolved_at": ms_to_iso(i.get("resolvedAt"))}
        for i in incidents])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--survey", action="append", help="Survey ID to export (repeatable). Default: all surveys.")
    parser.add_argument("--since", help="Only submissions created on/after this date (YYYY-MM-DD, UTC).")
    parser.add_argument("--until", help="With --analytics: last day of the period (YYYY-MM-DD, UTC). Default: today.")
    parser.add_argument("--analytics", action="store_true",
                        help="Save the submissions analytics summary instead of raw submissions. "
                             "Period defaults to the last 30 days.")
    parser.add_argument("--tables", action="store_true",
                        help="Write flat CSV tables (submissions, answers, incidents and lookups) to OUT/tables "
                             "for aggregating yourself. --since limits submissions and incidents.")
    parser.add_argument("--out", default="output", help="Output directory (default: output)")
    args = parser.parse_args()

    load_env(Path(__file__).with_name(".env"))
    business = os.environ.get("HARLYY_BUSINESS_ID")
    if not business:
        sys.exit("Set HARLYY_BUSINESS_ID in .env")
    token = get_access_token()

    out_dir = Path(args.out)
    out_dir.mkdir(exist_ok=True)

    if args.analytics:
        until = args.until or datetime.now(timezone.utc).strftime("%Y-%m-%d")
        since = args.since or (datetime.strptime(until, "%Y-%m-%d") - timedelta(days=29)).strftime("%Y-%m-%d")
        params = urllib.parse.urlencode({"periodStart": to_millis(since), "periodEnd": to_millis(until, True)})
        result = http_json("GET", f"{API_BASE}/v2/businesses/{business}/analytics/submissions?{params}", token)
        out_file = out_dir / f"analytics_submissions_{since}_{until}.json"
        out_file.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
        summary = result.get("data", {}).get("analytics", {})
        # Period totals get date "all"; daily buckets start at local midnight
        # (Lagos), so shift by 12h to read the local date from UTC.
        rows = analytics_rows(summary, "all")
        for bucket in result.get("data", {}).get("results") or []:
            day = datetime.fromtimestamp(bucket["timestamp"] / 1000 + 12 * 3600, timezone.utc).strftime("%Y-%m-%d")
            rows += analytics_rows(bucket.get("analytics") or {}, day)
        write_csv(out_file.with_suffix(".csv"), list(rows[0]), rows)
        print(f"{since} to {until}: {summary.get('submissions')} submissions, "
              f"{len(summary.get('locations', []))} locations -> {out_file}")
        return

    filters = []
    if args.since:
        filters.append({"field": "createdAt", "type": "gte", "value": to_millis(args.since)})

    survey_ids = args.survey or [s.strip() for s in os.environ.get("HARLYY_SURVEY_IDS", "").split(",") if s.strip()]
    if args.tables:
        export_tables(business, token, out_dir / "tables", filters, survey_ids)
        return
    if not survey_ids:
        # Listing surveys needs a staff token ("Staff is required"), but the
        # undocumented business-level submissions list works with the secret.
        submissions = fetch_all(f"/v2/businesses/{business}/submissions", token, filters)
        out_file = out_dir / "submissions_all.json"
        out_file.write_text(json.dumps(submissions, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"All surveys: {len(submissions)} submissions -> {out_file}")
        return

    for survey in survey_ids:
        submissions = fetch_all(f"/v2/businesses/{business}/surveys/{survey}/submissions", token, filters)
        out_file = out_dir / f"submissions_{survey}.json"
        out_file.write_text(json.dumps(submissions, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"{survey}: {len(submissions)} submissions -> {out_file}")


if __name__ == "__main__":
    main()
