"""Reconcile our figures with Harlyy's own dashboard (its analytics API) for a period.

For whole Lagos days START..END (inclusive), prints one table:

    metric | Harlyy dashboard | pipeline (our transform) | match

  Harlyy dashboard   Harlyy's analytics API: the numbers its app shows for that range
  pipeline           the raw records created in the range, run through build_tables() in
                     glue/harlyy_extract.py, i.e. exactly what the pipeline writes to Redshift

Then run sql/redshift/queries/reconcile_with_harlyy.sql in Redshift with the same dates:
its metric names and window are the same, so each Redshift figure should equal the
"Harlyy dashboard" column. A difference only in Redshift means a load problem (missed
hour, failed run); a difference in both means a rule we calculate differently.

Usage (needs HARLYY_CLIENT_SECRET and HARLYY_BUSINESS_ID in .env, read-only API calls):
    python tools/reconcile_with_harlyy.py --start 2026-11-01 --end 2026-11-15
    python tools/reconcile_with_harlyy.py --start 2026-11-01 --end 2026-11-15 --csv out.csv
"""

import argparse
import csv
import json
import math
import os
import sys
import urllib.parse
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "glue"))
import harlyy_extract as hx  # noqa: E402


class NoRecorder:
    def add(self, *_):
        pass


def harlyy_analytics(api, kind, start_ms, end_ms):
    query = urllib.parse.urlencode({"periodStart": start_ms, "periodEnd": end_ms})
    return api._get_json(f"{api.base}/analytics/{kind}?{query}")["data"]["analytics"]


def created_between(start_ms, end_ms):
    return [{"field": "createdAt", "type": "gte", "value": start_ms},
            {"field": "createdAt", "type": "lt", "value": end_ms}]


def smile(points, weight):
    return math.floor(100 * points / weight) if weight else 0


def pipeline_figures(rows, start_utc, end_utc):
    subs = rows["submissions"]
    ratings = defaultdict(int)
    points = weight = 0.0
    for a in rows["submission_answers"]:
        if a["step_type"] == "smileys" and a["rating"] is not None:
            ratings[a["rating"]] += 1
            points += a["smile_points"] or 0
            weight += a["smile_weight"] or 0
    # Harlyy: distinct customers per location per (Lagos) day, added up.
    per_day = defaultdict(set)
    for s in subs:
        if s["customer_id"]:
            lagos_day = (s["created_at"] + timedelta(hours=1)).date()
            per_day[(s["location_id"], lagos_day)].add(s["customer_id"])
    durations = [s["duration_ms"] for s in subs if s["duration_ms"] is not None]
    incs = [i for i in rows["incidents"] if i["is_survey_incident"]]
    revs = [r for r in rows["reviews"] if r["status"] == "active"
            and r["review_created_at"] and start_utc <= r["review_created_at"] < end_utc]
    replied = [r for r in revs if r["has_reply"]]
    return {
        "submissions": len(subs),
        "comments": sum(s["has_comment"] for s in subs),
        "customers": sum(len(c) for c in per_day.values()),
        "rating_1": ratings[1], "rating_2": ratings[2], "rating_3": ratings[3],
        "rating_4": ratings[4], "rating_5": ratings[5],
        "smile_score": smile(points, weight),
        "avg_time_seconds": round(sum(durations) / len(durations) / 1000) if durations else None,
        "incidents": len(incs),
        "incidents_reviewed": sum(1 for i in incs if i["reviewed_at"]),
        "incidents_resolved": sum(1 for i in incs if i["status"] == "resolved"),
        "reviews": len(revs),
        "reviews_replied": len(replied),
        "review_1_star": sum(r["rating"] == 1 for r in revs), "review_2_star": sum(r["rating"] == 2 for r in revs),
        "review_3_star": sum(r["rating"] == 3 for r in revs), "review_4_star": sum(r["rating"] == 4 for r in revs),
        "review_5_star": sum(r["rating"] == 5 for r in revs),
    }


def harlyy_figures(sub, inc, rev):
    stars = {1: "one", 2: "two", 3: "three", 4: "four", 5: "five"}
    out = {"submissions": sub["submissions"], "comments": sub["comments"], "customers": sub["customers"]}
    out.update({f"rating_{n}": sub["ratings"][w] for n, w in stars.items()})
    out.update({"smile_score": sub["smileScore"], "avg_time_seconds": round(sub["avgTime"] / 1000),
                "incidents": inc["incidents"], "incidents_reviewed": inc["reviewedIncidents"],
                "incidents_resolved": inc["resolvedIncidents"],
                "reviews": rev["reviews"], "reviews_replied": rev["repliedReviews"]})
    out.update({f"review_{n}_star": rev["ratings"][w] for n, w in stars.items()})
    return out


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--start", required=True, help="first day, YYYY-MM-DD (Lagos)")
    p.add_argument("--end", required=True, help="last day, YYYY-MM-DD (Lagos), inclusive")
    p.add_argument("--csv", help="also write the comparison to this CSV file")
    args = p.parse_args(argv)

    hx.load_env_file()
    if not (os.environ.get("HARLYY_CLIENT_SECRET") and os.environ.get("HARLYY_BUSINESS_ID")):
        raise SystemExit("Set HARLYY_CLIENT_SECRET and HARLYY_BUSINESS_ID in .env")
    api = hx.Harlyy(os.environ["HARLYY_BUSINESS_ID"], os.environ["HARLYY_CLIENT_SECRET"], NoRecorder())

    start = datetime.combine(date.fromisoformat(args.start), datetime.min.time(), tzinfo=hx.LAGOS)
    end = datetime.combine(date.fromisoformat(args.end) + timedelta(days=1), datetime.min.time(), tzinfo=hx.LAGOS)
    start_ms, end_ms = hx.ms(start), hx.ms(end)
    start_utc, end_utc = hx.utc(start_ms), hx.utc(end_ms)
    print(f"Period {args.start} 00:00 to {args.end} 24:00 Lagos (UTC {start_utc} to {end_utc})")

    harlyy = harlyy_figures(harlyy_analytics(api, "submissions", start_ms, end_ms),
                            harlyy_analytics(api, "incidents", start_ms, end_ms),
                            harlyy_analytics(api, "reviews", start_ms, end_ms))
    print("Fetching the period's records (read-only) ...")
    raw = hx.fetch(api, created_between(start_ms, end_ms))
    ours = pipeline_figures(hx.build_tables(raw), start_utc, end_utc)

    lines = [(m, harlyy[m], ours[m], "yes" if harlyy[m] == ours[m] else "NO") for m in harlyy]
    width = max(len(m) for m in harlyy)
    print(f"\n{'metric':<{width}}  {'Harlyy':>9}  {'pipeline':>9}  match")
    for m, h, o, ok in lines:
        print(f"{m:<{width}}  {h!s:>9}  {o!s:>9}  {ok}")
    print(f"\n{sum(ok == 'yes' for *_, ok in lines)} of {len(lines)} match. "
          "Now run sql/redshift/queries/reconcile_with_harlyy.sql with the same dates.")
    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["metric", "harlyy_dashboard", "pipeline_transform", "match"])
            w.writerows(lines)
        print(f"Written {args.csv}")
    print(json.dumps({"period": [args.start, args.end], "harlyy": harlyy}))


if __name__ == "__main__":
    main()
