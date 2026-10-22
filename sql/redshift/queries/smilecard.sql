-- Smilecard: Smile Score per location for a period, against the target and the
-- previous period of the same length, with the rating breakdown.
-- Matches Harlyy's Smile Score (weighted ratings, rounded down); see glue/harlyy_extract.py
-- SMILE_WEIGHTS. Needs sql/redshift/03_reporting_views.sql.
--
-- Change the dates and target in params. For a region, regional manager or brand view,
-- replace the location columns in level and GROUP BY; for the whole business, group by
-- nothing (remove them).

WITH params AS (
    SELECT DATE '2026-09-23' AS start_date,
           DATE '2026-10-22' AS end_date,
           64                AS target              -- Harlyy dashboard target
),
periods AS (
    SELECT start_date, end_date, target,
           DATEADD(day, -(DATEDIFF(day, start_date, end_date) + 1), start_date) AS prev_start,
           DATEADD(day, -1, start_date)                                          AS prev_end
    FROM params
),
level AS (
    SELECT d.region,
           d.regional_manager,
           d.location_name,
           CASE WHEN d.created_date BETWEEN p.start_date AND p.end_date THEN 'current' ELSE 'previous' END AS period,
           SUM(d.smile_points) AS smile_points,
           SUM(d.smile_weight) AS smile_weight,
           SUM(d.rating_1)     AS rating_1,
           SUM(d.rating_2)     AS rating_2,
           SUM(d.rating_3)     AS rating_3,
           SUM(d.rating_4)     AS rating_4,
           SUM(d.rating_5)     AS rating_5,
           SUM(d.submissions)  AS submissions
    FROM harlyy_feedback_analytics.vw_submission_analytics_daily d
    CROSS JOIN periods p
    WHERE d.created_date BETWEEN p.prev_start AND p.end_date
    GROUP BY 1, 2, 3, 4
),
scored AS (
    SELECT region, regional_manager, location_name, period, submissions,
           rating_1, rating_2, rating_3, rating_4, rating_5,
           rating_1 + rating_2 + rating_3 + rating_4 + rating_5                  AS total_ratings,
           FLOOR(100.0 * smile_points / NULLIF(smile_weight, 0))                 AS smile_score
    FROM level
)
SELECT c.region,
       c.regional_manager,
       c.location_name,
       c.smile_score,
       p.target,
       c.smile_score - p.target                                                  AS vs_target,
       pr.smile_score                                                            AS previous_smile_score,
       c.smile_score - pr.smile_score                                            AS vs_previous_period,
       c.total_ratings,
       c.submissions,
       ROUND(100.0 * c.rating_5 / NULLIF(c.total_ratings, 0), 2)                 AS pct_5_star,
       ROUND(100.0 * c.rating_4 / NULLIF(c.total_ratings, 0), 2)                 AS pct_4_star,
       ROUND(100.0 * c.rating_3 / NULLIF(c.total_ratings, 0), 2)                 AS pct_3_star,
       ROUND(100.0 * c.rating_2 / NULLIF(c.total_ratings, 0), 2)                 AS pct_2_star,
       ROUND(100.0 * c.rating_1 / NULLIF(c.total_ratings, 0), 2)                 AS pct_1_star
FROM scored c
CROSS JOIN params p
LEFT JOIN scored pr
       ON pr.period = 'previous'
      AND COALESCE(pr.region, '')           = COALESCE(c.region, '')
      AND COALESCE(pr.regional_manager, '') = COALESCE(c.regional_manager, '')
      AND COALESCE(pr.location_name, '')    = COALESCE(c.location_name, '')
WHERE c.period = 'current'
  AND c.total_ratings > 0
ORDER BY c.smile_score, c.total_ratings DESC;    -- lowest scores first: where to act
