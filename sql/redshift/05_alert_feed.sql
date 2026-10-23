-- Negative feedback feed for manager notifications. Run after 04_store_map.sql.
--
-- vw_negative_feedback: one row per negative item, refreshed by every hourly load.
--   Surveys:  main rating 1-2 stars
--   Reviews:  Google / Chowdeck, 1-2 stars or Harlyy sentiment "negative"
--
-- For the notifier:
--   * alert_id is stable and unique ("survey:sbm_..." / "review:rev_..."): record the
--     alert_ids you have sent and skip them next time, so nothing is sent twice.
--   * Only alert on recent items (is_recent = TRUE, posted in the last 48 hours).
--     Harlyy re-syncs old reviews in bulk, and the history load contains months of
--     past complaints; without this filter managers would be flooded.
--   * Route with store_number / area / regional_bu, from the company store master
--     (public.pulse_store_master_map, linked in 04_store_map.sql). store_match says how
--     the store was found:
--       location      the survey or review's Harlyy location
--       listing       the review's listing (all Chowdeck, a few Google)
--       from comment  an online/delivery survey whose comment names exactly one store
--                     (a guess: say so in the alert)
--       NULL          no store: send to the central / online team
--     harlyy_regional_manager is Harlyy's own label, for a fallback.
--   * New rows appear after each hourly load (about :05-:10 past the hour, Lagos).
--
-- Contains personal data (customer name and phone for survey complaints).

-- Dropped first: CREATE OR REPLACE cannot change a view's columns. Re-run the grants below after.
DROP VIEW IF EXISTS harlyy_feedback_analytics.vw_negative_feedback;

CREATE VIEW harlyy_feedback_analytics.vw_negative_feedback AS
WITH latest_incident AS (
    SELECT submission_id, code, status
    FROM (SELECT submission_id, code, status,
                 ROW_NUMBER() OVER (PARTITION BY submission_id ORDER BY created_at DESC) AS rn
          FROM harlyy_feedback_analytics.incidents
          WHERE is_survey_incident) x
    WHERE rn = 1
),
-- Store names, aliases and 5-digit store numbers as space-padded words, for finding them
-- in comments. Numbers: Paystack references start with the store number
-- ("51790-baa8..."), and some customers type it in the order field ("#51795").
-- Shorter numbers (Pinkberry 29, 93) would clash with order numbers, so are left out.
store_words AS (
    SELECT TRIM(brand) AS brand, country, store_number,
           ' ' || TRIM(REGEXP_REPLACE(UPPER(store_name), '[^A-Z0-9]+', ' ')) || ' ' AS word
    FROM public.pulse_store_master_map
    UNION ALL
    SELECT TRIM(brand), country, store_number, ' ' || CAST(store_number AS VARCHAR) || ' '
    FROM public.pulse_store_master_map
    WHERE store_number >= 10000
    UNION ALL
    SELECT a.brand, p.country, a.store_number,
           ' ' || TRIM(REGEXP_REPLACE(UPPER(a.alias), '[^A-Z0-9]+', ' ')) || ' '
    FROM harlyy_feedback_analytics.store_aliases a
    JOIN public.pulse_store_master_map p ON p.store_number = a.store_number
),
-- Negative surveys at a location with no store (online channels) whose comment names
-- exactly one store of the same brand and country.
comment_store AS (
    SELECT s.submission_id, MIN(w.store_number) AS store_number
    FROM harlyy_feedback_analytics.submissions s
    LEFT JOIN harlyy_feedback_analytics.surveys sv  ON sv.survey_id  = s.survey_id
    JOIN harlyy_feedback_analytics.locations l      ON l.location_id = s.location_id
    JOIN harlyy_feedback_analytics.vw_store_map sm  ON sm.map_key    = 'location:' || s.location_id
    JOIN store_words w
      ON w.country = l.country_code
     AND w.brand = CASE WHEN COALESCE(l.brand, sv.brand) ILIKE 'domino%'    THEN 'DP'
                        WHEN COALESCE(l.brand, sv.brand) ILIKE 'cold stone%' THEN 'CSC'
                        WHEN COALESCE(l.brand, sv.brand) ILIKE 'pinkberry%'  THEN 'PB' END
     AND POSITION(w.word IN ' ' || REGEXP_REPLACE(UPPER(s.comment_text), '[^A-Z0-9]+', ' ') || ' ') > 0
    WHERE s.overall_rating <= 2
      AND sm.store_number IS NULL
    GROUP BY s.submission_id
    HAVING COUNT(DISTINCT w.store_number) = 1
)
SELECT 'survey:' || s.submission_id                                  AS alert_id,
       'survey'                                                      AS source,
       s.submission_id                                               AS source_id,
       s.created_at                                                  AS event_at_utc,
       s.created_at_local                                            AS event_at_local,
       s.created_at >= DATEADD(hour, -48, GETDATE())                 AS is_recent,
       s.overall_rating                                              AS rating,
       CAST(NULL AS VARCHAR(64))                                     AS sentiment,
       s.comment_text                                                AS comment,
       s.location_id,
       CAST(NULL AS VARCHAR(128))                                    AS listing_id,
       COALESCE(l.location_name, 'Unknown location')                 AS store,
       COALESCE(l.brand, sv.brand)                                   AS brand,
       l.country_code,
       l.state,
       l.region,
       l.regional_manager                                            AS harlyy_regional_manager,
       COALESCE(sm.store_number, cm.store_number)                    AS store_number,
       COALESCE(sm.master_store_name, cm.store_name)                 AS master_store_name,
       COALESCE(sm.area, cm.area)                                    AS area,
       COALESCE(sm.regional_bu, cm.regional_bu)                      AS regional_bu,
       CASE WHEN sm.store_number IS NOT NULL THEN 'location'
            WHEN cm.store_number IS NOT NULL THEN 'from comment' END AS store_match,
       sv.survey_name                                                AS survey_or_platform,
       sv.channel,
       s.customer_name,
       s.customer_phone,
       i.code                                                        AS harlyy_incident_code,
       i.status                                                      AS harlyy_incident_status,
       CAST(NULL AS BOOLEAN)                                         AS has_reply,
       CAST(NULL AS VARCHAR(2048))                                   AS link,
       s.updated_at
FROM harlyy_feedback_analytics.submissions s
LEFT JOIN harlyy_feedback_analytics.surveys sv      ON sv.survey_id  = s.survey_id
LEFT JOIN harlyy_feedback_analytics.locations l     ON l.location_id = s.location_id
LEFT JOIN harlyy_feedback_analytics.vw_store_map sm ON sm.map_key    = 'location:' || s.location_id
LEFT JOIN comment_store cs                          ON cs.submission_id = s.submission_id
LEFT JOIN public.pulse_store_master_map cm          ON cm.store_number  = cs.store_number
LEFT JOIN latest_incident i                         ON i.submission_id = s.submission_id
WHERE s.overall_rating <= 2
UNION ALL
SELECT 'review:' || r.review_id,
       r.source,                                                     -- google / chowdeck
       r.review_id,
       r.review_created_at,
       DATEADD(hour, CASE WHEN COALESCE(l.country_code, r.country_code) = 'KE' THEN 3 ELSE 1 END,
               r.review_created_at),
       r.review_created_at >= DATEADD(hour, -48, GETDATE()),
       r.rating,
       r.sentiment,
       r.content,
       r.location_id,
       r.listing_id,
       COALESCE(l.location_name, r.listing_name),
       r.brand,
       COALESCE(l.country_code, r.country_code),
       l.state,
       l.region,
       l.regional_manager,
       sm.store_number,
       sm.master_store_name,
       sm.area,
       sm.regional_bu,
       CASE WHEN sm.store_number IS NULL THEN NULL
            WHEN r.location_id IS NOT NULL THEN 'location'
            ELSE 'listing' END,
       r.listing_name,
       CAST(NULL AS VARCHAR(64)),
       r.customer_name,
       CAST(NULL AS VARCHAR(64)),
       CAST(NULL AS VARCHAR(64)),
       CAST(NULL AS VARCHAR(64)),
       r.has_reply,
       r.source_url,
       r.updated_at
FROM harlyy_feedback_analytics.reviews r
LEFT JOIN harlyy_feedback_analytics.locations l     ON l.location_id = r.location_id
LEFT JOIN harlyy_feedback_analytics.vw_store_map sm
       ON sm.map_key = CASE WHEN r.location_id IS NOT NULL THEN 'location:' || r.location_id
                            ELSE 'listing:' || r.listing_id END
WHERE r.status = 'active'
  AND (r.rating <= 2 OR r.sentiment = 'negative')
WITH NO SCHEMA BINDING;


-- Read access for the developer's notifier (replace notifier_user with its Redshift user).
-- GRANT USAGE ON SCHEMA harlyy_feedback_analytics TO notifier_user;
-- GRANT SELECT ON harlyy_feedback_analytics.vw_negative_feedback TO notifier_user;
-- Late-binding views check the reader's access to the tables underneath, so also:
-- GRANT SELECT ON harlyy_feedback_analytics.submissions, harlyy_feedback_analytics.surveys,
--                 harlyy_feedback_analytics.locations, harlyy_feedback_analytics.incidents,
--                 harlyy_feedback_analytics.reviews, harlyy_feedback_analytics.store_map_overrides,
--                 harlyy_feedback_analytics.store_aliases, harlyy_feedback_analytics.vw_store_map
--              TO notifier_user;
-- GRANT USAGE ON SCHEMA public TO notifier_user;
-- GRANT SELECT ON public.pulse_store_master_map TO notifier_user;

-- What the notifier would run each hour:
-- SELECT * FROM harlyy_feedback_analytics.vw_negative_feedback
-- WHERE is_recent
--   AND alert_id NOT IN (SELECT alert_id FROM <notifier's sent log>)
-- ORDER BY event_at_utc;

-- How the online surveys came out (store_match = 'from comment' are guesses to spot-check):
-- SELECT store, store_match, master_store_name, LEFT(comment, 150) AS comment
-- FROM harlyy_feedback_analytics.vw_negative_feedback
-- WHERE source = 'survey' AND store LIKE 'Online%'
-- ORDER BY store_match NULLS LAST, event_at_utc DESC;
