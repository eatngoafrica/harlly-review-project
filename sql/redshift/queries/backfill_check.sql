-- Backfill check: is every day (and hour) present in Redshift?
-- Change the dates in each query if needed, then run each query separately.
-- Days and hours are Lagos time, as created_date / created_hour are stored.


-- 1. Rows per day: submissions, incidents and reviews.
--    A day with 0, or far below its neighbours, was not loaded.
WITH days AS (
    SELECT DATEADD(day, n, '2026-11-01'::date)::date AS day
    FROM (SELECT ROW_NUMBER() OVER (ORDER BY submission_id) - 1 AS n FROM harlyy_feedback_analytics.submissions LIMIT 60) nums
    WHERE DATEADD(day, n, '2026-11-01'::date) <= '2026-11-10'::date
)
SELECT d.day,
       TO_CHAR(d.day, 'Dy')                               AS weekday,
       COALESCE(s.submissions, 0)                         AS submissions,
       COALESCE(s.completed, 0)                           AS completed,
       COALESCE(i.incidents, 0)                           AS incidents,
       COALESCE(r.reviews, 0)                             AS reviews
FROM days d
LEFT JOIN (SELECT created_date, COUNT(*) AS submissions, SUM(CASE WHEN is_completed THEN 1 ELSE 0 END) AS completed
           FROM harlyy_feedback_analytics.submissions GROUP BY created_date) s ON s.created_date = d.day
LEFT JOIN (SELECT created_date, COUNT(*) AS incidents
           FROM harlyy_feedback_analytics.incidents GROUP BY created_date) i ON i.created_date = d.day
LEFT JOIN (SELECT review_date, COUNT(*) AS reviews
           FROM harlyy_feedback_analytics.reviews GROUP BY review_date) r ON r.review_date = d.day
ORDER BY d.day;


-- 2. Hours with no submissions at all between the two dates.
--    Night hours (stores closed) are normal; a run of daytime hours means a gap.
WITH hours AS (
    SELECT DATEADD(hour, n, '2026-11-04'::timestamp) AS hour_start
    FROM (SELECT ROW_NUMBER() OVER (ORDER BY submission_id) - 1 AS n FROM harlyy_feedback_analytics.submissions LIMIT 1000) nums
    WHERE DATEADD(hour, n, '2026-11-04'::timestamp) < '2026-11-11'::timestamp
)
SELECT h.hour_start::date             AS day,
       EXTRACT(hour FROM h.hour_start) AS hour_lagos
FROM hours h
LEFT JOIN harlyy_feedback_analytics.submissions s
       ON s.created_date = h.hour_start::date
      AND s.created_hour = EXTRACT(hour FROM h.hour_start)
WHERE h.hour_start <= DATEADD(hour, 1, GETDATE())   -- ignore hours still to come (GETDATE is UTC)
GROUP BY 1, 2
HAVING COUNT(s.submission_id) = 0
ORDER BY 1, 2;


-- 3. How fresh each table is: the newest change it holds (UTC).
--    After the backfill and hourly runs, these should be within the last hour or two.
SELECT 'submissions' AS table_name, MAX(updated_at) AS newest_change_utc, COUNT(*) AS total_rows FROM harlyy_feedback_analytics.submissions
UNION ALL SELECT 'incidents', MAX(updated_at), COUNT(*) FROM harlyy_feedback_analytics.incidents
UNION ALL SELECT 'reviews',   MAX(updated_at), COUNT(*) FROM harlyy_feedback_analytics.reviews
ORDER BY 1;
