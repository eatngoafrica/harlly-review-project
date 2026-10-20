"""Export survey submissions from the Harlyy API to JSON files.

Docs: https://docs.harlyy.com (see /api/surveys, /api/submissions, /querying)

Configuration is read from a .env file next to this script (see .env.example).

Usage:
    python harlyy_export.py                 # all surveys, all submissions
    python harlyy_export.py --since 2026-10-01
    python harlyy_export.py --survey SURVEY_ID --survey OTHER_ID
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

API_BASE = "https://api.harlyy.com"
AUTH_BASE = "https://auth.harlyy.com"
PAGE_SIZE = 100


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
    token = os.environ.get("HARLYY_ACCESS_TOKEN")
    if token:
        return token
    client_id = os.environ.get("HARLYY_CLIENT_ID")
    client_secret = os.environ.get("HARLYY_CLIENT_SECRET")
    if not (client_id and client_secret):
        sys.exit("Set HARLYY_ACCESS_TOKEN, or HARLYY_CLIENT_ID and HARLYY_CLIENT_SECRET, in .env")
    # The docs say /oauth/token accepts "credentials" but only show the
    # authorization_code grant, so the client_credentials grant is unconfirmed.
    result = http_json("POST", f"{AUTH_BASE}/oauth/token", body={
        "clientId": client_id,
        "clientSecret": client_secret,
        "grantType": "client_credentials",
    })
    return result["accessToken"]


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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--survey", action="append", help="Survey ID to export (repeatable). Default: all surveys.")
    parser.add_argument("--since", help="Only submissions created on/after this date (YYYY-MM-DD, UTC).")
    parser.add_argument("--out", default="output", help="Output directory (default: output)")
    args = parser.parse_args()

    load_env(Path(__file__).with_name(".env"))
    business = os.environ.get("HARLYY_BUSINESS_ID")
    if not business:
        sys.exit("Set HARLYY_BUSINESS_ID in .env")
    token = get_access_token()

    filters = []
    if args.since:
        since = datetime.strptime(args.since, "%Y-%m-%d").replace(tzinfo=timezone.utc)
        filters.append({"field": "createdAt", "type": "gte", "value": int(since.timestamp() * 1000)})

    survey_ids = args.survey or [s.strip() for s in os.environ.get("HARLYY_SURVEY_IDS", "").split(",") if s.strip()]
    if not survey_ids:
        surveys = fetch_all(f"/v2/businesses/{business}/surveys", token)
        survey_ids = [s.get("id") or s.get("_id") for s in surveys]
        print(f"Found {len(survey_ids)} surveys")

    out_dir = Path(args.out)
    out_dir.mkdir(exist_ok=True)
    for survey in survey_ids:
        submissions = fetch_all(f"/v2/businesses/{business}/surveys/{survey}/submissions", token, filters)
        out_file = out_dir / f"submissions_{survey}.json"
        out_file.write_text(json.dumps(submissions, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"{survey}: {len(submissions)} submissions -> {out_file}")


if __name__ == "__main__":
    main()
