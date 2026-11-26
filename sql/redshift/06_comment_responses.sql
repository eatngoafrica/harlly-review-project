-- Customer comments and the team's response. Run after 03_reporting_views.sql and
-- 04_store_map.sql (it reads vw_review_actions).
--
-- vw_comment_responses: one row per customer comment, answered or not.
--   Surveys:  every submission with a text answer (Harlyy's "comments")
--   Reviews:  every active Google / Chowdeck review with written text
--
-- Who commented:  commenter_name (customer; "Anonymous" when none was given),
--                 commenter_phone for surveys (personal data).
-- Who responded:
--   Surveys   The team responds through the Harlyy incident raised from the survey.
--             response_text = the staff note on the incident (the resolution note, else
--             the latest note; all notes are in incident_comments, query 5 below),
--             note_count = how many notes; responded_by = staff who resolved it, else
--             who marked it in review, else who wrote the note; assigned_to = the
--             incident's assignees. Survey comments with no incident (Harlyy raises
--             incidents for low ratings only) show 'No incident raised'.
--   Reviews   response_text is the reply posted on Google / Chowdeck. Harlyy does not
--             record who posted a reply, so responded_by says 'Not recorded by Harlyy'.
--
-- response_status   Replied / Not replied (reviews);
--                   Resolved / In review / Open - no response / No incident raised (surveys)
-- has_response      TRUE when replied, in review or resolved
-- action_priority   1 negative, no response   2 mixed, no response   3 positive, no response
--                   4 responded               5 survey comment with no incident (FYI only)
--                   6 old review: not replied but posted more than 7 days ago. History
--                     only, do NOT contact the customer. Harlyy re-syncs old Google
--                     reviews in bulk (some from 2021-2022); they keep their real
--                     posting date (commented_at_utc), so age is judged by that.
-- hours_to_response comment -> first response (review reply; or the first of incident
--                   reviewed, resolved or first staff note)
-- hours_waiting     comment -> now, while there is no response
--
-- Times: *_utc as stored; commented_at_local / comment_date in the store's time zone
-- (Lagos, Nairobi for Kenya). Refreshed by every hourly load.

DROP VIEW IF EXISTS harlyy_feedback_analytics.vw_comment_responses;

CREATE VIEW harlyy_feedback_analytics.vw_comment_responses AS
WITH latest_incident AS (       -- a survey can raise more than one incident: take the newest
    SELECT *
    FROM (SELECT i.*, ROW_NUMBER() OVER (PARTITION BY i.submission_id ORDER BY i.created_at DESC) AS rn
          FROM harlyy_feedback_analytics.incidents i
          WHERE i.is_survey_incident) x
    WHERE rn = 1
),
assignees AS (
    SELECT i.incident_id, LISTAGG(DISTINCT st.name, '; ') WITHIN GROUP (ORDER BY st.name) AS assigned_to
    FROM latest_incident i
    JOIN harlyy_feedback_analytics.staff st ON POSITION(st.staff_id IN i.assignee_ids) > 0
    GROUP BY i.incident_id
),
notes AS (                       -- staff notes per incident
    SELECT incident_id, COUNT(*) AS note_count, MIN(created_at) AS first_note_at
    FROM harlyy_feedback_analytics.incident_comments
    GROUP BY incident_id
),
main_note AS (                   -- the resolution note, else the latest note
    SELECT incident_id, staff_id, content
    FROM (SELECT c.incident_id, c.staff_id, c.content,
                 ROW_NUMBER() OVER (PARTITION BY c.incident_id
                                    ORDER BY CASE WHEN c.is_resolution_note THEN 0 ELSE 1 END,
                                             c.created_at DESC) AS rn
          FROM harlyy_feedback_analytics.incident_comments c) x
    WHERE rn = 1
),
comments AS (
    -- Survey comments
    SELECT 'survey:' || s.submission_id                                      AS comment_id,
           'survey'                                                           AS source,
           s.submission_id                                                    AS source_id,
           s.created_at                                                       AS commented_at_utc,
           s.created_at_local                                                 AS commented_at_local,
           s.created_date                                                     AS comment_date,
           COALESCE(s.customer_name, 'Anonymous')                             AS commenter_name,
           s.customer_phone                                                   AS commenter_phone,
           s.overall_rating                                                   AS rating,
           CASE WHEN s.overall_rating <= 2 THEN 'negative'
                WHEN s.overall_rating = 3  THEN 'mixed'
                WHEN s.overall_rating >= 4 THEN 'positive'
                ELSE 'unrated' END                                            AS tone,
           s.comment_text                                                     AS comment,
           COALESCE(l.brand, sv.brand)                                        AS brand,
           COALESCE(l.location_name, 'Unknown location')                      AS store,
           s.location_id,
           l.country_code,
           l.state,
           l.region,
           l.regional_manager,
           sv.survey_name                                                     AS survey_or_platform,
           sv.channel,
           i.code                                                             AS incident_code,
           i.status                                                           AS incident_status,
           CASE WHEN i.incident_id IS NULL      THEN 'No incident raised'
                WHEN i.status = 'resolved'      THEN 'Resolved'
                WHEN i.reviewed_at IS NOT NULL
                  OR i.status = 'in-review'
                  OR n.note_count > 0           THEN 'In review'
                ELSE 'Open - no response' END                                 AS response_status,
           COALESCE(rs.name, rv.name, nb.name)                                AS responded_by,
           rv.name                                                            AS reviewed_by,
           rs.name                                                            AS resolved_by,
           a.assigned_to,
           mn.content                                                         AS response_text,
           n.note_count,
           -- earliest of reviewed / resolved (reviewed always comes first) and the first note
           CASE WHEN n.first_note_at < COALESCE(i.reviewed_at, i.resolved_at, n.first_note_at)
                THEN n.first_note_at
                ELSE COALESCE(i.reviewed_at, i.resolved_at, n.first_note_at) END AS first_response_at_utc,
           i.resolved_at                                                      AS resolved_at_utc,
           CAST(NULL AS VARCHAR(2048))                                        AS link
    FROM harlyy_feedback_analytics.submissions s
    LEFT JOIN harlyy_feedback_analytics.surveys sv   ON sv.survey_id  = s.survey_id
    LEFT JOIN harlyy_feedback_analytics.locations l  ON l.location_id = s.location_id
    LEFT JOIN latest_incident i                      ON i.submission_id = s.submission_id
    LEFT JOIN harlyy_feedback_analytics.staff rv     ON rv.staff_id   = i.reviewed_by
    LEFT JOIN harlyy_feedback_analytics.staff rs     ON rs.staff_id   = i.resolved_by
    LEFT JOIN assignees a                            ON a.incident_id = i.incident_id
    LEFT JOIN notes n                                ON n.incident_id = i.incident_id
    LEFT JOIN main_note mn                           ON mn.incident_id = i.incident_id
    LEFT JOIN harlyy_feedback_analytics.staff nb     ON nb.staff_id   = mn.staff_id
    WHERE s.has_comment
    UNION ALL
    -- Google / Chowdeck reviews (same columns, same order)
    SELECT 'review:' || r.review_id,
           r.source,                                                          -- google / chowdeck
           r.review_id,
           r.review_created_at,
           DATEADD(hour, CASE WHEN r.country_code = 'KE' THEN 3 ELSE 1 END, r.review_created_at),
           r.review_date,
           COALESCE(NULLIF(TRIM(r.customer_name), ''), 'Anonymous'),
           CAST(NULL AS VARCHAR(64)),
           r.rating,
           r.review_tone,
           r.content,
           r.brand,
           r.store,
           r.location_id,
           r.country_code,
           r.state,
           r.region,
           r.regional_manager,
           r.listing_name,
           CAST(NULL AS VARCHAR(64)),
           CAST(NULL AS VARCHAR(64)),
           CAST(NULL AS VARCHAR(64)),
           CASE WHEN r.has_reply THEN 'Replied' ELSE 'Not replied' END,
           CASE WHEN r.has_reply THEN 'Not recorded by Harlyy' END,
           CAST(NULL AS VARCHAR(512)),
           CAST(NULL AS VARCHAR(512)),
           CAST(NULL AS VARCHAR(65535)),
           r.reply_content,
           CAST(NULL AS BIGINT),                                              -- note_count
           r.replied_at,
           CAST(NULL AS TIMESTAMP),
           r.source_url
    FROM harlyy_feedback_analytics.vw_review_actions r
    WHERE NULLIF(TRIM(r.content), '') IS NOT NULL
      -- To include rating-only reviews (no text) too, remove the line above.
)
SELECT c.*,
       c.response_status IN ('Replied', 'Resolved', 'In review')             AS has_response,
       CASE WHEN c.response_status = 'No incident raised'                     THEN 5
            WHEN c.response_status IN ('Replied', 'Resolved', 'In review')    THEN 4
            WHEN c.source <> 'survey'
             AND c.commented_at_utc < DATEADD(day, -7, GETDATE())             THEN 6
            WHEN c.tone = 'negative'                                          THEN 1
            WHEN c.tone = 'mixed'                                             THEN 2
            ELSE 3 END                                                        AS action_priority,
       ROUND(DATEDIFF(minute, c.commented_at_utc, c.first_response_at_utc) / 60.0, 1) AS hours_to_response,
       CASE WHEN c.first_response_at_utc IS NULL AND c.response_status <> 'No incident raised'
            THEN ROUND(DATEDIFF(minute, c.commented_at_utc, GETDATE()) / 60.0, 1) END AS hours_waiting
FROM comments c
WITH NO SCHEMA BINDING;


-- Readers need SELECT on the tables underneath as well (late-binding view), e.g.:
-- GRANT SELECT ON harlyy_feedback_analytics.vw_comment_responses TO <user>;


-- ---------------------------------------------------------------------------------
-- Ready-made queries (run one at a time)
-- ---------------------------------------------------------------------------------

-- 1. Quick response: everything still waiting, worst and oldest first.
-- SELECT action_priority, hours_waiting, comment_date, source, brand, store, region, regional_manager,
--        commenter_name, commenter_phone, rating, LEFT(comment, 300) AS comment,
--        response_status, incident_code, assigned_to, link
-- FROM harlyy_feedback_analytics.vw_comment_responses
-- WHERE NOT has_response AND action_priority IN (1, 2, 3)
--   AND commented_at_utc >= DATEADD(day, -14, GETDATE())
-- ORDER BY action_priority, commented_at_utc;

-- 2. Full log for a period: who commented, who responded, when.
-- SELECT comment_date, commented_at_local, source, brand, store, region, regional_manager,
--        commenter_name, rating, tone, comment,
--        response_status, responded_by, assigned_to, response_text, note_count,
--        first_response_at_utc, hours_to_response, incident_code
-- FROM harlyy_feedback_analytics.vw_comment_responses
-- WHERE comment_date BETWEEN DATE '2026-11-01' AND DATE '2026-11-15'
-- ORDER BY commented_at_utc DESC;

-- 3. Response performance per regional manager and channel.
-- SELECT COALESCE(regional_manager, 'Not set') AS regional_manager, source,
--        COUNT(*)                                                       AS comments,
--        SUM(CASE WHEN tone = 'negative' THEN 1 ELSE 0 END)             AS negative,
--        SUM(CASE WHEN action_priority <> 5 THEN 1 ELSE 0 END)          AS needing_response,
--        SUM(CASE WHEN action_priority <> 5 AND has_response THEN 1 ELSE 0 END) AS responded,
--        ROUND(100.0 * SUM(CASE WHEN action_priority <> 5 AND has_response THEN 1 ELSE 0 END)
--              / NULLIF(SUM(CASE WHEN action_priority <> 5 THEN 1 ELSE 0 END), 0), 1) AS response_rate_pct,
--        ROUND(AVG(hours_to_response), 1)                               AS avg_hours_to_response,
--        SUM(CASE WHEN action_priority IN (1, 2, 3) THEN 1 ELSE 0 END)  AS still_waiting
-- FROM harlyy_feedback_analytics.vw_comment_responses
-- WHERE comment_date BETWEEN DATE '2026-11-01' AND DATE '2026-11-15'
-- GROUP BY 1, 2
-- ORDER BY still_waiting DESC, response_rate_pct;

-- 4. Who on the team responds to survey complaints, and how fast.
-- SELECT responded_by, COUNT(*) AS incidents_handled,
--        SUM(CASE WHEN response_status = 'Resolved' THEN 1 ELSE 0 END) AS resolved,
--        ROUND(AVG(hours_to_response), 1) AS avg_hours_to_first_response
-- FROM harlyy_feedback_analytics.vw_comment_responses
-- WHERE source = 'survey' AND responded_by IS NOT NULL
--   AND comment_date >= DATEADD(day, -30, CURRENT_DATE)
-- GROUP BY responded_by
-- ORDER BY incidents_handled DESC;

-- 5. Every staff note on survey complaints: the full conversation, oldest first.
-- SELECT i.code AS incident_code, i.status, i.created_at AS incident_at_utc,
--        l.location_name AS store, l.regional_manager,
--        s.customer_name, s.overall_rating, LEFT(s.comment_text, 200) AS customer_comment,
--        st.name AS note_by, st.position, c.created_at AS note_at_utc,
--        c.is_resolution_note, c.content AS note
-- FROM harlyy_feedback_analytics.incident_comments c
-- JOIN harlyy_feedback_analytics.incidents i        ON i.incident_id  = c.incident_id
-- LEFT JOIN harlyy_feedback_analytics.staff st      ON st.staff_id    = c.staff_id
-- LEFT JOIN harlyy_feedback_analytics.submissions s ON s.submission_id = i.submission_id
-- LEFT JOIN harlyy_feedback_analytics.locations l   ON l.location_id  = i.location_id
-- WHERE i.created_at >= DATEADD(day, -30, GETDATE())
-- ORDER BY i.created_at DESC, c.created_at;
