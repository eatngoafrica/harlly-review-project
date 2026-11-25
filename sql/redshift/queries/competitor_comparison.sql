/*
Harlyy's Competitors page from our own tables: for each topic group (Customer Service,
Food & Beverage, Ambiance, Delivery Experience) and each topic under it, one row per
company (Eat N'Go and every tracked competitor brand) with review count, sentiment
split, a score, our rank and the leader. Needs sql/redshift/07_review_topics.sql.

Matches Harlyy:
  reviews      per topic: reviews mentioning it; per group: the topics' counts added up,
               as Harlyy does (a review naming two topics of a group counts twice).
               Checked 25 Nov 2026 against Harlyy's last-30-days page: Eat N'Go 23,
               Burger King Nigeria 5, Panarottis 3, Debonairs none.
Not yet matched:
  score        PROVISIONAL: 100 x (positive + half of neutral) / all mentions, rounded
               down. Within ~3 points of Harlyy's figures; Harlyy has not published its
               formula. Replace the score_formula line once they confirm it.

Period: by when the customer posted the review (Lagos). Set it in params; Harlyy's
default page is the last 30 days to the current minute (use the commented lines).
*/
WITH params AS (
    SELECT DATEADD(hour, -1, DATE '2026-10-26'::timestamp)                 AS start_utc,  -- 26 Oct 00:00 Lagos
           DATEADD(hour, -1, DATEADD(day, 1, DATE '2026-11-24')::timestamp) AS end_utc     -- 24 Nov 24:00 Lagos
    -- Harlyy's "Last 30 days":
    -- SELECT DATEADD(day, -30, GETDATE()) AS start_utc, GETDATE() AS end_utc
),
mentions AS (
    SELECT m.*
    FROM harlyy_feedback_analytics.vw_topic_mentions m
    CROSS JOIN params p
    WHERE m.review_created_at >= p.start_utc AND m.review_created_at < p.end_utc
      AND m.topic_group IS NOT NULL
),
by_topic AS (           -- one row per company x topic
    SELECT company, topic_group, topic,
           COUNT(DISTINCT review_key)                               AS reviews,
           COUNT(*)                                                 AS mentions,
           SUM(CASE WHEN sentiment = 'positive' THEN 1 ELSE 0 END)  AS positive,
           SUM(CASE WHEN sentiment = 'neutral'  THEN 1 ELSE 0 END)  AS neutral,
           SUM(CASE WHEN sentiment = 'negative' THEN 1 ELSE 0 END)  AS negative
    FROM mentions
    GROUP BY 1, 2, 3
),
rolled AS (             -- topic rows, plus one 'All topics' row per group
    SELECT company, topic_group, topic, reviews, mentions, positive, neutral, negative FROM by_topic
    UNION ALL
    SELECT company, topic_group, 'All topics', SUM(reviews), SUM(mentions), SUM(positive), SUM(neutral), SUM(negative)
    FROM by_topic
    GROUP BY 1, 2
),
scored AS (
    SELECT r.*,
           FLOOR(100.0 * (positive + 0.5 * neutral) / NULLIF(mentions, 0))     AS score,   -- score_formula (provisional)
           ROUND(100.0 * positive / NULLIF(mentions, 0), 1)                    AS pct_positive,
           ROUND(100.0 * neutral  / NULLIF(mentions, 0), 1)                    AS pct_neutral,
           ROUND(100.0 * negative / NULLIF(mentions, 0), 1)                    AS pct_negative
    FROM rolled r
),
ranked AS (
    SELECT s.*,
           RANK() OVER (PARTITION BY topic_group, topic ORDER BY score DESC)     AS rank_in_topic,
           FIRST_VALUE(company) OVER (PARTITION BY topic_group, topic ORDER BY score DESC, reviews DESC
                                      ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS leader
    FROM scored s
)
SELECT topic_group, topic, company, score, reviews, mentions, pct_positive, pct_neutral, pct_negative,
       rank_in_topic, leader
FROM ranked
ORDER BY topic_group,
         CASE WHEN topic = 'All topics' THEN 0 ELSE 1 END, topic,
         CASE WHEN company = 'Eat N''Go' THEN 0 ELSE 1 END, score DESC;

-- Just Eat N'Go's rank per group (Harlyy's "#10 - Leader: Pizza Hut Nigeria"): add
--   WHERE topic = 'All topics' AND company = 'Eat N''Go'
-- before the ORDER BY of the final SELECT.
