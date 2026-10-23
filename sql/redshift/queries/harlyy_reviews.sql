-- Harlyy Reviews dashboard, from our own tables: Google and Chowdeck reviews for a period,
-- per platform and per store. Needs sql/redshift/03_reporting_views.sql and
-- 04_store_map.sql. Set the period (Lagos dates) in params of each query.
--
-- Stars: for the period here; Harlyy's 3rd Party Reviews card shows all-time stars
-- (see harlyy_overview.sql). Reply time is from the review to our reply.


-- 1. Per platform: totals, stars, rating breakdown, sentiment, replies.
WITH params AS (
    SELECT DATE '2026-09-23' AS start_date,
           DATE '2026-10-22' AS end_date
)
SELECT r.source,
       COUNT(*)                                                               AS reviews,
       ROUND(AVG(r.rating::FLOAT), 1)                                         AS avg_stars,
       SUM(CASE WHEN r.rating = 5 THEN 1 ELSE 0 END)                          AS stars_5,
       SUM(CASE WHEN r.rating = 4 THEN 1 ELSE 0 END)                          AS stars_4,
       SUM(CASE WHEN r.rating = 3 THEN 1 ELSE 0 END)                          AS stars_3,
       SUM(CASE WHEN r.rating = 2 THEN 1 ELSE 0 END)                          AS stars_2,
       SUM(CASE WHEN r.rating = 1 THEN 1 ELSE 0 END)                          AS stars_1,
       SUM(CASE WHEN r.sentiment = 'positive' THEN 1 ELSE 0 END)              AS positive,
       SUM(CASE WHEN r.sentiment IN ('neutral', 'mixed') THEN 1 ELSE 0 END)   AS neutral_mixed,
       SUM(CASE WHEN r.sentiment = 'negative' THEN 1 ELSE 0 END)              AS negative,
       SUM(CASE WHEN r.has_reply THEN 1 ELSE 0 END)                           AS replied,
       ROUND(100.0 * SUM(CASE WHEN r.has_reply THEN 1 ELSE 0 END) / COUNT(*), 1) AS reply_rate_pct,
       ROUND(AVG(r.minutes_to_reply) / 60.0, 1)                               AS avg_hours_to_reply,
       SUM(CASE WHEN NOT r.has_reply AND r.review_tone = 'negative' THEN 1 ELSE 0 END) AS negative_unreplied
FROM harlyy_feedback_analytics.vw_review_actions r
CROSS JOIN params p
WHERE r.review_date BETWEEN p.start_date AND p.end_date
GROUP BY r.source
ORDER BY r.source;


-- 2. Per store: the same figures, lowest stars first. Store comes from the company store
--    master (location, or the listing for Chowdeck), so Google and Chowdeck reviews of one
--    store sit together.
WITH params AS (
    SELECT DATE '2026-09-23' AS start_date,
           DATE '2026-10-22' AS end_date
)
SELECT COALESCE(sm.regional_bu, 'No store')                                   AS regional_bu,
       sm.area,
       sm.store_brand                                                         AS brand,
       COALESCE(sm.master_store_name, r.store)                                AS store,
       sm.store_number,
       COUNT(*)                                                               AS reviews,
       SUM(CASE WHEN r.source = 'google'   THEN 1 ELSE 0 END)                 AS google_reviews,
       SUM(CASE WHEN r.source = 'chowdeck' THEN 1 ELSE 0 END)                 AS chowdeck_reviews,
       ROUND(AVG(r.rating::FLOAT), 1)                                         AS avg_stars,
       ROUND(AVG(CASE WHEN r.source = 'google'   THEN r.rating::FLOAT END), 1) AS google_stars,
       ROUND(AVG(CASE WHEN r.source = 'chowdeck' THEN r.rating::FLOAT END), 1) AS chowdeck_stars,
       SUM(CASE WHEN r.review_tone = 'negative' THEN 1 ELSE 0 END)            AS negative,
       ROUND(100.0 * SUM(CASE WHEN r.has_reply THEN 1 ELSE 0 END) / COUNT(*), 1) AS reply_rate_pct,
       SUM(CASE WHEN NOT r.has_reply AND r.review_tone = 'negative' THEN 1 ELSE 0 END) AS negative_unreplied
FROM harlyy_feedback_analytics.vw_review_actions r
JOIN harlyy_feedback_analytics.reviews rv ON rv.review_id = r.review_id
CROSS JOIN params p
LEFT JOIN harlyy_feedback_analytics.vw_store_map sm
       ON sm.map_key = CASE WHEN rv.location_id IS NOT NULL THEN 'location:' || rv.location_id
                            ELSE 'listing:' || rv.listing_id END
WHERE r.review_date BETWEEN p.start_date AND p.end_date
GROUP BY 1, 2, 3, 4, 5
ORDER BY avg_stars, reviews DESC;
