-- Reporting views over harlyy_feedback_analytics. Run after 01_tables.sql.
-- Late-binding (WITH NO SCHEMA BINDING), so table changes never need the views dropped first.


-- ---------------------------------------------------------------------------------
-- 1. vw_submission_analytics_daily
--    Our own copy of Harlyy's Submission Analytics, one row per local day x survey x
--    location. Every column adds up, so roll it up to any period or level with SUM:
--
--      submissions      SUM(submissions)                       (Harlyy: any answered step)
--      customers        SUM(customers)                         (distinct per location per day, as Harlyy)
--      comments         SUM(comments)
--      ratings 1-5      SUM(rating_1) ... SUM(rating_5)
--      Smile Score      FLOOR(100.0 * SUM(smile_points) / NULLIF(SUM(smile_weight), 0))
--      incidents        SUM(incidents)
--      resolved %       100.0 * SUM(incidents_resolved) / NULLIF(SUM(incidents), 0)
--      avg time (min)   SUM(total_duration_ms) / NULLIF(SUM(submissions), 0) / 60000.0
--
--    Days are local time (Lagos / Nairobi); Harlyy uses Lagos time for every store, so
--    Kenyan stores can differ slightly near midnight.
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE VIEW harlyy_feedback_analytics.vw_submission_analytics_daily AS
WITH ratings AS (
    SELECT submission_id,
           SUM(CASE WHEN rating = 1 THEN 1 ELSE 0 END) AS rating_1,
           SUM(CASE WHEN rating = 2 THEN 1 ELSE 0 END) AS rating_2,
           SUM(CASE WHEN rating = 3 THEN 1 ELSE 0 END) AS rating_3,
           SUM(CASE WHEN rating = 4 THEN 1 ELSE 0 END) AS rating_4,
           SUM(CASE WHEN rating = 5 THEN 1 ELSE 0 END) AS rating_5,
           SUM(smile_points)                           AS smile_points,
           SUM(smile_weight)                           AS smile_weight
    FROM harlyy_feedback_analytics.submission_answers
    WHERE step_type = 'smileys' AND rating IS NOT NULL      -- every rating Harlyy counts
    GROUP BY submission_id
),
incs AS (
    SELECT submission_id,
           COUNT(*)                                              AS incidents,
           SUM(CASE WHEN status = 'resolved' THEN 1 ELSE 0 END)  AS incidents_resolved
    FROM harlyy_feedback_analytics.incidents
    WHERE is_survey_incident
    GROUP BY submission_id
)
SELECT s.created_date,
       s.survey_id,
       sv.survey_name,
       sv.channel,
       s.location_id,
       l.location_name,
       COALESCE(l.brand, sv.brand)                              AS brand,
       l.country,
       l.state,
       l.region,
       l.regional_manager,
       COUNT(*)                                                  AS submissions,
       SUM(CASE WHEN s.is_completed THEN 1 ELSE 0 END)           AS completed,
       COUNT(DISTINCT s.customer_id)                             AS customers,
       SUM(CASE WHEN s.has_comment THEN 1 ELSE 0 END)            AS comments,
       COALESCE(SUM(r.rating_1), 0)                              AS rating_1,
       COALESCE(SUM(r.rating_2), 0)                              AS rating_2,
       COALESCE(SUM(r.rating_3), 0)                              AS rating_3,
       COALESCE(SUM(r.rating_4), 0)                              AS rating_4,
       COALESCE(SUM(r.rating_5), 0)                              AS rating_5,
       COALESCE(SUM(r.smile_points), 0)                          AS smile_points,
       COALESCE(SUM(r.smile_weight), 0)                          AS smile_weight,
       COALESCE(SUM(i.incidents), 0)                             AS incidents,
       COALESCE(SUM(i.incidents_resolved), 0)                    AS incidents_resolved,
       SUM(s.duration_ms)                                        AS total_duration_ms
FROM harlyy_feedback_analytics.submissions s
LEFT JOIN ratings r                              ON r.submission_id = s.submission_id
LEFT JOIN incs i                                 ON i.submission_id = s.submission_id
LEFT JOIN harlyy_feedback_analytics.surveys sv   ON sv.survey_id    = s.survey_id
LEFT JOIN harlyy_feedback_analytics.locations l  ON l.location_id   = s.location_id
GROUP BY s.created_date, s.survey_id, sv.survey_name, sv.channel, s.location_id, l.location_name,
         COALESCE(l.brand, sv.brand), l.country, l.state, l.region, l.regional_manager
WITH NO SCHEMA BINDING;


-- ---------------------------------------------------------------------------------
-- 2. vw_review_actions
--    Every Google / Chowdeck review with its store, region and regional manager, and a
--    priority for replying:
--      1 = negative and not replied   2 = mixed / 3-star and not replied
--      3 = positive and not replied   4 = already replied
--    Google listings are linked to a Harlyy location, so they get region and regional
--    manager. Chowdeck listings are not linked in Harlyy: they show the listing name and
--    brand, with region and regional_manager blank until someone links them in Harlyy.
--    Reply times: *_minutes for sorting and filtering, *_text for reading
--    (45m, 3h 05m, 8d 19h).
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE VIEW harlyy_feedback_analytics.vw_review_actions AS
SELECT r.*,
       CASE WHEN r.minutes_to_reply IS NULL THEN NULL
            WHEN r.minutes_to_reply < 60     THEN CAST(r.minutes_to_reply AS VARCHAR) || 'm'
            WHEN r.minutes_to_reply < 1440   THEN CAST(r.minutes_to_reply / 60 AS VARCHAR) || 'h '
                                                  || LPAD(CAST(r.minutes_to_reply % 60 AS VARCHAR), 2, '0') || 'm'
            ELSE CAST(r.minutes_to_reply / 1440 AS VARCHAR) || 'd '
                 || CAST((r.minutes_to_reply % 1440) / 60 AS VARCHAR) || 'h' END        AS time_to_reply_text,
       CASE WHEN r.minutes_waiting IS NULL THEN NULL
            WHEN r.minutes_waiting < 60     THEN CAST(r.minutes_waiting AS VARCHAR) || 'm'
            WHEN r.minutes_waiting < 1440   THEN CAST(r.minutes_waiting / 60 AS VARCHAR) || 'h '
                                                 || LPAD(CAST(r.minutes_waiting % 60 AS VARCHAR), 2, '0') || 'm'
            ELSE CAST(r.minutes_waiting / 1440 AS VARCHAR) || 'd '
                 || CAST((r.minutes_waiting % 1440) / 60 AS VARCHAR) || 'h' END         AS time_waiting_text
FROM (
    SELECT r.review_id,
           r.source,
           r.review_date,
           r.review_created_at,
           r.rating,
           r.sentiment,
           CASE WHEN r.rating <= 2 OR r.sentiment = 'negative'                  THEN 'negative'
                WHEN r.rating = 3  OR r.sentiment IN ('mixed', 'neutral')      THEN 'mixed'
                ELSE 'positive' END                                             AS review_tone,
           r.content,
           r.customer_name,
           r.has_reply,
           r.reply_content,
           r.replied_at,
           DATEDIFF(minute, r.review_created_at, r.replied_at)                  AS minutes_to_reply,
           CASE WHEN NOT r.has_reply
                THEN DATEDIFF(minute, r.review_created_at, GETDATE()) END      AS minutes_waiting,
           CASE WHEN r.has_reply                                     THEN 4
                WHEN r.rating <= 2 OR r.sentiment = 'negative'       THEN 1
                WHEN r.rating = 3  OR r.sentiment = 'mixed'          THEN 2
                ELSE 3 END                                                      AS action_priority,
           r.brand,
           COALESCE(l.location_name, r.listing_name)                            AS store,
           r.listing_name,
           r.location_id,
           COALESCE(l.country_code, r.country_code)                             AS country_code,
           l.state,
           COALESCE(l.city, r.city)                                             AS city,
           l.region,
           l.regional_manager,
           r.source_url
    FROM harlyy_feedback_analytics.reviews r
    LEFT JOIN harlyy_feedback_analytics.locations l ON l.location_id = r.location_id
    WHERE r.status = 'active'
) r
WITH NO SCHEMA BINDING;


-- Quick react: unreplied negative and mixed reviews from the last 7 days, worst first.
-- SELECT action_priority, time_waiting_text, source, brand, store, region, regional_manager,
--        rating, sentiment, LEFT(content, 200) AS content, source_url
-- FROM harlyy_feedback_analytics.vw_review_actions
-- WHERE action_priority IN (1, 2)
--   AND review_created_at >= DATEADD(day, -7, GETDATE())
-- ORDER BY action_priority, minutes_waiting DESC;
