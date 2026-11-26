/*
Harlyy dashboard Overview exactly as Harlyy's default "Last 30 days" shows it: from this
moment 30 days ago up to now, against the 30 days before that. Run it any time, no dates
to edit. Same cards as harlyy_overview.sql (which takes whole Lagos days instead).

Harlyy's window runs to the current minute; ours ends at the last hourly load (about :10
past the hour), so in between, Harlyy can show a few more submissions than this.
Review stars: average of the reviews we hold (posted from 1 Jan 2026, plus older ones
Harlyy has re-synced). Harlyy's 3rd Party Reviews card averages each listing's whole
history, so it shows more (25 Nov 2026: Google 4.1 vs ours 4.0, Chowdeck 3.3 vs 2.9).
*/
WITH params AS (
    SELECT GETDATE() AS end_at,           -- now (UTC, as the tables store it)
           30        AS days              -- Harlyy: Last 7 / 30 / 90 days
),
periods AS (
    SELECT end_at,
           DATEADD(day, -days, end_at)     AS start_at,
           DATEADD(day, -2 * days, end_at) AS prev_start
    FROM params
),
subs AS (
    SELECT s.submission_id,
           CASE WHEN s.created_at >= p.start_at THEN 'current' ELSE 'previous' END AS period
    FROM harlyy_feedback_analytics.submissions s
    CROSS JOIN periods p
    WHERE s.created_at >= p.prev_start AND s.created_at < p.end_at
),
ratings AS (
    SELECT submission_id,
           SUM(CASE WHEN rating = 1 THEN 1 ELSE 0 END) AS r1,
           SUM(CASE WHEN rating = 2 THEN 1 ELSE 0 END) AS r2,
           SUM(CASE WHEN rating = 3 THEN 1 ELSE 0 END) AS r3,
           SUM(CASE WHEN rating = 4 THEN 1 ELSE 0 END) AS r4,
           SUM(CASE WHEN rating = 5 THEN 1 ELSE 0 END) AS r5,
           SUM(smile_points)                           AS smile_points,
           SUM(smile_weight)                           AS smile_weight
    FROM harlyy_feedback_analytics.submission_answers
    WHERE step_type = 'smileys' AND rating IS NOT NULL
    GROUP BY submission_id
),
incs AS (
    SELECT submission_id,
           COUNT(*)                                             AS incidents,
           SUM(CASE WHEN status = 'resolved' THEN 1 ELSE 0 END) AS resolved
    FROM harlyy_feedback_analytics.incidents
    WHERE is_survey_incident
    GROUP BY submission_id
),
surveys AS (
    SELECT x.period,
           COUNT(*)                         AS submissions,
           COALESCE(SUM(i.incidents), 0)    AS incidents,
           COALESCE(SUM(i.resolved), 0)     AS resolved,
           COALESCE(SUM(r.smile_points), 0) AS smile_points,
           COALESCE(SUM(r.smile_weight), 0) AS smile_weight,
           COALESCE(SUM(r.r1), 0) AS r1, COALESCE(SUM(r.r2), 0) AS r2, COALESCE(SUM(r.r3), 0) AS r3,
           COALESCE(SUM(r.r4), 0) AS r4, COALESCE(SUM(r.r5), 0) AS r5
    FROM subs x
    LEFT JOIN ratings r ON r.submission_id = x.submission_id
    LEFT JOIN incs i    ON i.submission_id = x.submission_id
    GROUP BY x.period
),
-- Harlyy's Total Incidents also counts incidents with no survey (counts_in_harlyy):
-- review incidents (since 21 Nov 2026) and actionable photo / document incidents.
-- Counted by when the incident was created.
review_incs AS (
    SELECT CASE WHEN i.created_at >= p.start_at THEN 'current' ELSE 'previous' END AS period,
           COUNT(*)                                               AS incidents,
           SUM(CASE WHEN i.status = 'resolved' THEN 1 ELSE 0 END) AS resolved
    FROM harlyy_feedback_analytics.incidents i
    CROSS JOIN periods p
    WHERE i.counts_in_harlyy AND NOT i.is_survey_incident
      AND i.created_at >= p.prev_start AND i.created_at < p.end_at
    GROUP BY 1
),
totals AS (
    SELECT s.period, s.submissions,
           s.incidents + COALESCE(ri.incidents, 0) AS incidents,
           s.resolved  + COALESCE(ri.resolved, 0)  AS resolved,
           s.smile_points, s.smile_weight, s.r1, s.r2, s.r3, s.r4, s.r5
    FROM surveys s
    LEFT JOIN review_incs ri ON ri.period = s.period
),
cur AS (SELECT * FROM totals WHERE period = 'current'),
prev AS (SELECT * FROM totals WHERE period = 'previous'),
reviews AS (
    SELECT r.source,
           SUM(CASE WHEN r.review_created_at >= p.start_at AND r.review_created_at < p.end_at
                    THEN 1 ELSE 0 END)                                              AS reviews_in_period,
           ROUND(AVG(r.rating::FLOAT), 1)                                           AS stars_all_time,
           ROUND(AVG(CASE WHEN r.review_created_at < p.start_at THEN r.rating::FLOAT END), 1) AS stars_at_prev_end
    FROM harlyy_feedback_analytics.reviews r
    CROSS JOIN periods p
    WHERE r.status = 'active'
    GROUP BY r.source
)
SELECT
    -- Window, Lagos time
    DATEADD(hour, 1, p.start_at)                                                       AS from_lagos,
    DATEADD(hour, 1, p.end_at)                                                         AS to_lagos,
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
    ROUND(g.stars_all_time - g.stars_at_prev_end, 1)                                   AS google_stars_change,
    ch.reviews_in_period                                                               AS chowdeck_reviews,
    ch.stars_all_time                                                                  AS chowdeck_stars,
    ROUND(ch.stars_all_time - ch.stars_at_prev_end, 1)                                 AS chowdeck_stars_change,
    COALESCE(g.reviews_in_period, 0) + COALESCE(ch.reviews_in_period, 0)               AS total_reviews
FROM cur c
CROSS JOIN periods p
LEFT JOIN prev pv ON TRUE
LEFT JOIN reviews g  ON g.source  = 'google'
LEFT JOIN reviews ch ON ch.source = 'chowdeck';
