/*
Why the feedback page (built on notification_feed.sql) shows more than the Harlyy
dashboard. Set the same period as the Harlyy link in params (UTC; Lagos is UTC+1).
Run each query separately.

The Harlyy dashboard's negative figures are SURVEYS only (Ratings card: 1 and 2 stars,
every channel and status). Reviews are on Harlyy's separate Reviews page. The feed adds
Google / Chowdeck reviews to the same list, and leaves out Website and star-only
abandoned surveys, so its total is not comparable with any one Harlyy card.
*/

-- 1. Our counts side by side with Harlyy's cards.
WITH params AS (
    SELECT TIMESTAMP '2026-10-26 09:00:00' AS start_utc,     -- 26 Oct 10:00 Lagos
           TIMESTAMP '2026-11-24 23:00:00' AS end_utc        -- 25 Nov 00:00 Lagos
)
SELECT 'Harlyy Ratings card: 1 + 2 stars (all surveys)' AS figure,
       COUNT(*) AS value
FROM harlyy_feedback_analytics.submissions s CROSS JOIN params p
WHERE s.overall_rating IN (1, 2) AND s.created_at >= p.start_utc AND s.created_at < p.end_utc
UNION ALL
SELECT 'Feed: surveys (no Website, no star-only abandoned)', COUNT(*)
FROM harlyy_feedback_analytics.submissions s
JOIN harlyy_feedback_analytics.surveys sv ON sv.survey_id = s.survey_id
CROSS JOIN params p
WHERE s.overall_rating IN (1, 2) AND s.created_at >= p.start_utc AND s.created_at < p.end_utc
  AND sv.channel <> 'Website'
  AND (s.is_completed OR NULLIF(TRIM(s.comment_text), '') IS NOT NULL)
UNION ALL
SELECT 'Harlyy Reviews page: 1 + 2 star reviews', COUNT(*)
FROM harlyy_feedback_analytics.reviews r CROSS JOIN params p
WHERE r.status = 'active' AND r.rating IN (1, 2)
  AND r.review_created_at >= p.start_utc AND r.review_created_at < p.end_utc
UNION ALL
SELECT 'Harlyy Incidents card', COUNT(*)
FROM harlyy_feedback_analytics.incidents i CROSS JOIN params p
WHERE i.counts_in_harlyy AND i.created_at >= p.start_utc AND i.created_at < p.end_utc;


-- 2. Duplicates: each should return no rows. A row here means a complaint is counted
--    more than once in the feed (a store linked twice in the store map).
SELECT map_key, COUNT(*) AS rows_for_key
FROM harlyy_feedback_analytics.vw_store_map
GROUP BY map_key HAVING COUNT(*) > 1;

SELECT alert_id, COUNT(*) AS rows_for_alert
FROM harlyy_feedback_analytics.vw_negative_feedback
GROUP BY alert_id HAVING COUNT(*) > 1;


-- 3. Does the app's database user have access? Replace app_user (3 places) with its
--    Redshift user name (SELECT usename FROM pg_user; or ask the app's developer).
--    Every row should say true. Late-binding views check the tables underneath for
--    the reader too, so those are listed as well.
SELECT 'schema harlyy_feedback_analytics' AS object,
       HAS_SCHEMA_PRIVILEGE('app_user', 'harlyy_feedback_analytics', 'USAGE') AS has_access
UNION ALL
SELECT 'schema public', HAS_SCHEMA_PRIVILEGE('app_user', 'public', 'USAGE')
UNION ALL
SELECT t.obj, HAS_TABLE_PRIVILEGE('app_user', t.obj, 'SELECT')
FROM (          SELECT 'harlyy_feedback_analytics.submissions' AS obj
      UNION ALL SELECT 'harlyy_feedback_analytics.submission_answers'
      UNION ALL SELECT 'harlyy_feedback_analytics.surveys'
      UNION ALL SELECT 'harlyy_feedback_analytics.locations'
      UNION ALL SELECT 'harlyy_feedback_analytics.incidents'
      UNION ALL SELECT 'harlyy_feedback_analytics.reviews'
      UNION ALL SELECT 'harlyy_feedback_analytics.store_map_overrides'
      UNION ALL SELECT 'harlyy_feedback_analytics.store_aliases'
      UNION ALL SELECT 'harlyy_feedback_analytics.vw_store_map'
      UNION ALL SELECT 'harlyy_feedback_analytics.vw_negative_feedback'
      UNION ALL SELECT 'public.pulse_store_master_map') t
ORDER BY 2, 1;

-- To fix any false row (as the schema owner or an admin):
-- GRANT USAGE ON SCHEMA harlyy_feedback_analytics TO app_user;
-- GRANT USAGE ON SCHEMA public TO app_user;
-- GRANT SELECT ON harlyy_feedback_analytics.<table or view> TO app_user;
-- GRANT SELECT ON public.pulse_store_master_map TO app_user;


-- 4. Who has access: names instead of true/false. Run as an admin or superuser to see
--    everyone (others see only their own grants).

-- 4a. Every user, group and role granted SELECT on what the feed reads, one row per grant.
SELECT identity_type, identity_name, namespace_name AS schema_name, relation_name
FROM svv_relation_privileges
WHERE privilege_type = 'SELECT'
  AND namespace_name || '.' || relation_name IN (
        'harlyy_feedback_analytics.submissions', 'harlyy_feedback_analytics.submission_answers',
        'harlyy_feedback_analytics.surveys', 'harlyy_feedback_analytics.locations',
        'harlyy_feedback_analytics.incidents', 'harlyy_feedback_analytics.reviews',
        'harlyy_feedback_analytics.store_map_overrides', 'harlyy_feedback_analytics.store_aliases',
        'harlyy_feedback_analytics.vw_store_map', 'harlyy_feedback_analytics.vw_negative_feedback',
        'public.pulse_store_master_map')
ORDER BY identity_type, identity_name, schema_name, relation_name;

-- 4b. One row per user / group / role: how many of the 11 it can read. 11 = can run the
--     feed (plus schema USAGE, 4c). missing lists the rest.
WITH needed AS (
              SELECT 'harlyy_feedback_analytics.submissions' AS obj
    UNION ALL SELECT 'harlyy_feedback_analytics.submission_answers'
    UNION ALL SELECT 'harlyy_feedback_analytics.surveys'
    UNION ALL SELECT 'harlyy_feedback_analytics.locations'
    UNION ALL SELECT 'harlyy_feedback_analytics.incidents'
    UNION ALL SELECT 'harlyy_feedback_analytics.reviews'
    UNION ALL SELECT 'harlyy_feedback_analytics.store_map_overrides'
    UNION ALL SELECT 'harlyy_feedback_analytics.store_aliases'
    UNION ALL SELECT 'harlyy_feedback_analytics.vw_store_map'
    UNION ALL SELECT 'harlyy_feedback_analytics.vw_negative_feedback'
    UNION ALL SELECT 'public.pulse_store_master_map'
),
granted AS (
    SELECT DISTINCT identity_type, identity_name, namespace_name || '.' || relation_name AS obj
    FROM svv_relation_privileges
    WHERE privilege_type = 'SELECT'
),
who AS (SELECT DISTINCT identity_type, identity_name FROM granted g JOIN needed n ON n.obj = g.obj)
SELECT w.identity_type, w.identity_name,
       SUM(CASE WHEN g.obj IS NOT NULL THEN 1 ELSE 0 END) AS can_read_of_11,
       LISTAGG(CASE WHEN g.obj IS NULL THEN n.obj END, ', ') AS missing
FROM who w
CROSS JOIN needed n
LEFT JOIN granted g ON g.identity_type = w.identity_type AND g.identity_name = w.identity_name AND g.obj = n.obj
GROUP BY 1, 2
ORDER BY can_read_of_11 DESC, 1, 2;

-- 4c. Who has USAGE on the two schemas (needed as well as SELECT).
SELECT namespace_name AS schema_name, identity_type, identity_name
FROM svv_schema_privileges
WHERE privilege_type = 'USAGE'
  AND namespace_name IN ('harlyy_feedback_analytics', 'public')
ORDER BY 1, 2, 3;

-- 4d. Grants to a group or role reach every member: who is in them.
SELECT 'group' AS via, g.groname AS name, u.usename AS user_name
FROM pg_group g
JOIN pg_user u ON u.usesysid = ANY(g.grolist)
UNION ALL
SELECT 'role', role_name, user_name
FROM svv_user_grants
ORDER BY 1, 2, 3;

-- 4e. Not listed above but can read everything: superusers and the tables' owners.
SELECT 'superuser' AS why, usename AS user_name FROM pg_user WHERE usesuper
UNION
SELECT 'owner of ' || schemaname || '.' || tablename, tableowner
FROM pg_tables
WHERE schemaname = 'harlyy_feedback_analytics' OR (schemaname = 'public' AND tablename = 'pulse_store_master_map')
ORDER BY 1, 2;
