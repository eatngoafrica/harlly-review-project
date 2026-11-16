/*
Reconcile Redshift with the Harlyy app for a period: one row per metric.

1. Run  python tools/reconcile_with_harlyy.py --start 2026-11-01 --end 2026-11-15
   It prints Harlyy's own figures (its analytics API = what the app shows) next to
   what our transform produces.
2. Run this query with the same dates in params. Each value should equal the
   "Harlyy" column. Paste the tool's JSON line into harlyy_value below to have the
   difference worked out for you (optional).

Window: whole Lagos days, start 00:00 to end 24:00, by creation time, as Harlyy does
for every store (Kenya included). Figures for the last hour or two can be ahead in
Harlyy until the next hourly load.

Checked 16 Nov 2026 for 1-15 Nov: every metric matched Harlyy except avg_time_seconds
(Harlyy 302, ours 305): Harlyy's average time is no longer exactly updatedAt - createdAt;
a known difference of about 1%.
*/
WITH params AS (
    SELECT DATE '2026-11-01' AS start_date,
           DATE '2026-11-15' AS end_date
),
win AS (    -- Lagos is UTC+1 all year; the tables store UTC
    SELECT DATEADD(hour, -1, start_date::timestamp)                       AS start_utc,
           DATEADD(hour, -1, DATEADD(day, 1, end_date)::timestamp)       AS end_utc
    FROM params
),
subs AS (
    SELECT s.*
    FROM harlyy_feedback_analytics.submissions s
    CROSS JOIN win w
    WHERE s.created_at >= w.start_utc AND s.created_at < w.end_utc
),
answers AS (
    SELECT a.rating, a.smile_points, a.smile_weight
    FROM harlyy_feedback_analytics.submission_answers a
    JOIN subs s ON s.submission_id = a.submission_id
    WHERE a.step_type = 'smileys' AND a.rating IS NOT NULL
),
customers AS (   -- Harlyy: distinct customers per location per Lagos day, added up
    SELECT SUM(n) AS customers
    FROM (SELECT location_id, DATEADD(hour, 1, created_at)::date AS lagos_day, COUNT(DISTINCT customer_id) AS n
          FROM subs GROUP BY 1, 2) x
),
incs AS (
    SELECT i.*
    FROM harlyy_feedback_analytics.incidents i
    CROSS JOIN win w
    WHERE i.is_survey_incident AND i.created_at >= w.start_utc AND i.created_at < w.end_utc
),
revs AS (
    SELECT r.*
    FROM harlyy_feedback_analytics.reviews r
    CROSS JOIN win w
    WHERE r.status = 'active' AND r.review_created_at >= w.start_utc AND r.review_created_at < w.end_utc
),
ours AS (
              SELECT 1 AS n, 'submissions' AS metric, COUNT(*)::BIGINT AS redshift_value FROM subs
    UNION ALL SELECT 2,  'comments',           SUM(CASE WHEN has_comment THEN 1 ELSE 0 END) FROM subs
    UNION ALL SELECT 3,  'customers',          customers FROM customers
    UNION ALL SELECT 4,  'rating_1',           SUM(CASE WHEN rating = 1 THEN 1 ELSE 0 END) FROM answers
    UNION ALL SELECT 5,  'rating_2',           SUM(CASE WHEN rating = 2 THEN 1 ELSE 0 END) FROM answers
    UNION ALL SELECT 6,  'rating_3',           SUM(CASE WHEN rating = 3 THEN 1 ELSE 0 END) FROM answers
    UNION ALL SELECT 7,  'rating_4',           SUM(CASE WHEN rating = 4 THEN 1 ELSE 0 END) FROM answers
    UNION ALL SELECT 8,  'rating_5',           SUM(CASE WHEN rating = 5 THEN 1 ELSE 0 END) FROM answers
    UNION ALL SELECT 9,  'smile_score',        FLOOR(100.0 * SUM(smile_points) / NULLIF(SUM(smile_weight), 0))::BIGINT FROM answers
    UNION ALL SELECT 10, 'avg_time_seconds',   ROUND(AVG(duration_ms) / 1000.0)::BIGINT FROM subs
    UNION ALL SELECT 11, 'incidents',          COUNT(*) FROM incs
    UNION ALL SELECT 12, 'incidents_reviewed', SUM(CASE WHEN reviewed_at IS NOT NULL THEN 1 ELSE 0 END) FROM incs
    UNION ALL SELECT 13, 'incidents_resolved', SUM(CASE WHEN status = 'resolved' THEN 1 ELSE 0 END) FROM incs
    UNION ALL SELECT 14, 'reviews',            COUNT(*) FROM revs
    UNION ALL SELECT 15, 'reviews_replied',    SUM(CASE WHEN has_reply THEN 1 ELSE 0 END) FROM revs
    UNION ALL SELECT 16, 'review_1_star',      SUM(CASE WHEN rating = 1 THEN 1 ELSE 0 END) FROM revs
    UNION ALL SELECT 17, 'review_2_star',      SUM(CASE WHEN rating = 2 THEN 1 ELSE 0 END) FROM revs
    UNION ALL SELECT 18, 'review_3_star',      SUM(CASE WHEN rating = 3 THEN 1 ELSE 0 END) FROM revs
    UNION ALL SELECT 19, 'review_4_star',      SUM(CASE WHEN rating = 4 THEN 1 ELSE 0 END) FROM revs
    UNION ALL SELECT 20, 'review_5_star',      SUM(CASE WHEN rating = 5 THEN 1 ELSE 0 END) FROM revs
),
-- Optional: paste the JSON line the tool prints (the "harlyy" object) between the quotes.
harlyy AS (
    SELECT '' AS j
)
SELECT o.metric,
       o.redshift_value,
       NULLIF(JSON_EXTRACT_PATH_TEXT(NULLIF(h.j, ''), 'harlyy', o.metric), '')::BIGINT  AS harlyy_value,
       o.redshift_value - NULLIF(JSON_EXTRACT_PATH_TEXT(NULLIF(h.j, ''), 'harlyy', o.metric), '')::BIGINT AS difference
FROM ours o
CROSS JOIN harlyy h
ORDER BY o.n;
