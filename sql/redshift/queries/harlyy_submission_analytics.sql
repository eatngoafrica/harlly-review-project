/*
Harlyy Submission Analytics dashboard, from our own tables: one row per survey and
location for a period, with the same measures Harlyy shows (submissions, customers,
comments, ratings, Smile Score, incidents, resolved, average time).
Needs sql/redshift/03_reporting_views.sql. Set the period (Lagos dates) in params.

For one total row per survey, remove location_name from SELECT and GROUP BY; for the
whole business, remove both survey_name and location_name.
*/
WITH params AS (
    SELECT DATE '2026-09-23' AS start_date,
           DATE '2026-10-22' AS end_date
)
SELECT d.survey_name,
       d.channel,
       d.location_name,
       SUM(d.submissions)                                                     AS submissions,
       SUM(d.completed)                                                       AS completed,
       SUM(d.customers)                                                       AS customers,
       SUM(d.comments)                                                        AS comments,
       SUM(d.rating_1 + d.rating_2 + d.rating_3 + d.rating_4 + d.rating_5)    AS ratings,
       FLOOR(100.0 * SUM(d.smile_points) / NULLIF(SUM(d.smile_weight), 0))    AS smile_score,
       SUM(d.incidents)                                                       AS incidents,
       ROUND(100.0 * SUM(d.incidents_resolved) / NULLIF(SUM(d.incidents), 0), 1) AS resolved_pct,
       ROUND(SUM(d.total_duration_ms) / NULLIF(SUM(d.submissions), 0) / 60000.0, 1) AS avg_time_minutes
FROM harlyy_feedback_analytics.vw_submission_analytics_daily d
CROSS JOIN params p
WHERE d.created_date BETWEEN p.start_date AND p.end_date
GROUP BY d.survey_name, d.channel, d.location_name
ORDER BY submissions DESC;
