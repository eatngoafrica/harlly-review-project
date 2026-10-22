-- Harlyy dashboard Overview, from our own tables: Smile Score, Submissions, Total
-- Incidents, Resolved, Rating Breakdown and 3rd Party Reviews, each with the change
-- against the previous period of the same length.
-- Needs sql/redshift/03_reporting_views.sql. Set the period (Lagos dates) in params.
--
-- Harlyy shows the change as points for Smile Score and Resolved, and as a percent for
-- counts; both are given here. Review stars are all-time averages per platform, as
-- Harlyy shows them; the review counts are for the period.
--
-- Comparing with the dashboard: pick a custom range of whole days in Harlyy. Its
-- "Last 30 days" starts at the current time of day 30 days ago (e.g. 10:00), which a
-- whole-day query cannot match.

WITH params AS (
    SELECT DATE '2026-09-23' AS start_date,
           DATE '2026-10-22' AS end_date
),
periods AS (
    SELECT start_date, end_date,
           DATEADD(day, -(DATEDIFF(day, start_date, end_date) + 1), start_date) AS prev_start,
           DATEADD(day, -1, start_date)                                          AS prev_end
    FROM params
),
surveys AS (
    SELECT CASE WHEN d.created_date >= p.start_date THEN 'current' ELSE 'previous' END AS period,
           SUM(d.submissions)        AS submissions,
           SUM(d.incidents)          AS incidents,
           SUM(d.incidents_resolved) AS resolved,
           SUM(d.smile_points)       AS smile_points,
           SUM(d.smile_weight)       AS smile_weight,
           SUM(d.rating_1) AS r1, SUM(d.rating_2) AS r2, SUM(d.rating_3) AS r3,
           SUM(d.rating_4) AS r4, SUM(d.rating_5) AS r5
    FROM harlyy_feedback_analytics.vw_submission_analytics_daily d
    CROSS JOIN periods p
    WHERE d.created_date BETWEEN p.prev_start AND p.end_date
    GROUP BY 1
),
cur AS (SELECT * FROM surveys WHERE period = 'current'),
prev AS (SELECT * FROM surveys WHERE period = 'previous'),
reviews AS (
    SELECT r.source,
           SUM(CASE WHEN r.review_date BETWEEN p.start_date AND p.end_date THEN 1 ELSE 0 END) AS reviews_in_period,
           ROUND(AVG(CASE WHEN r.review_date <= p.end_date  THEN r.rating::FLOAT END), 1)    AS stars_all_time,
           ROUND(AVG(CASE WHEN r.review_date <= p.prev_end  THEN r.rating::FLOAT END), 1)    AS stars_at_prev_end
    FROM harlyy_feedback_analytics.reviews r
    CROSS JOIN periods p
    WHERE r.status = 'active'
    GROUP BY r.source
)
SELECT
    -- Smile Score
    FLOOR(100.0 * c.smile_points / NULLIF(c.smile_weight, 0))                          AS smile_score,
    FLOOR(100.0 * c.smile_points / NULLIF(c.smile_weight, 0))
      - FLOOR(100.0 * pv.smile_points / NULLIF(pv.smile_weight, 0))                    AS smile_score_vs_prev_points,
    64                                                                                 AS smile_score_target,
    -- Submissions
    c.submissions,
    ROUND(100.0 * (c.submissions - pv.submissions) / NULLIF(pv.submissions, 0), 1)     AS submissions_vs_prev_pct,
    -- Total Incidents
    c.incidents,
    ROUND(100.0 * (c.incidents - pv.incidents) / NULLIF(pv.incidents, 0), 1)           AS incidents_vs_prev_pct,
    -- Resolved
    ROUND(100.0 * c.resolved / NULLIF(c.incidents, 0), 2)                              AS resolved_pct,
    ROUND(100.0 * c.resolved / NULLIF(c.incidents, 0)
          - 100.0 * pv.resolved / NULLIF(pv.incidents, 0), 1)                          AS resolved_vs_prev_points,
    -- Rating Breakdown (count and share of all ratings)
    c.r1 + c.r2 + c.r3 + c.r4 + c.r5                                                   AS total_ratings,
    c.r5, ROUND(100.0 * c.r5 / NULLIF(c.r1 + c.r2 + c.r3 + c.r4 + c.r5, 0), 2)         AS pct_5,
    c.r4, ROUND(100.0 * c.r4 / NULLIF(c.r1 + c.r2 + c.r3 + c.r4 + c.r5, 0), 2)         AS pct_4,
    c.r3, ROUND(100.0 * c.r3 / NULLIF(c.r1 + c.r2 + c.r3 + c.r4 + c.r5, 0), 2)         AS pct_3,
    c.r2, ROUND(100.0 * c.r2 / NULLIF(c.r1 + c.r2 + c.r3 + c.r4 + c.r5, 0), 2)         AS pct_2,
    c.r1, ROUND(100.0 * c.r1 / NULLIF(c.r1 + c.r2 + c.r3 + c.r4 + c.r5, 0), 2)         AS pct_1,
    -- 3rd Party Reviews
    g.reviews_in_period                                                                AS google_reviews,
    g.stars_all_time                                                                   AS google_stars,
    g.stars_all_time - g.stars_at_prev_end                                             AS google_stars_change,
    ch.reviews_in_period                                                               AS chowdeck_reviews,
    ch.stars_all_time                                                                  AS chowdeck_stars,
    ch.stars_all_time - ch.stars_at_prev_end                                           AS chowdeck_stars_change,
    COALESCE(g.reviews_in_period, 0) + COALESCE(ch.reviews_in_period, 0)               AS total_reviews
FROM cur c
LEFT JOIN prev pv ON TRUE
LEFT JOIN reviews g  ON g.source  = 'google'
LEFT JOIN reviews ch ON ch.source = 'chowdeck';
