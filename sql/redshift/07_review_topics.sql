-- Review topics, ours and competitors', side by side. Run after 01_tables.sql (and the
-- 2026-11-25 migration). Feeds sql/redshift/queries/competitor_comparison.sql.
--
-- vw_topic_mentions: one row per sentence per topic (Harlyy's review categories, e.g.
-- Wait Time) in a Google / Chowdeck review, for Eat'N'Go and for the competitor brands
-- the pipeline tracks (COMPETITOR_BRANDS in glue/harlyy_extract.py).
--   company        'Eat N''Go' for our reviews, else the competitor brand (Harlyy's name,
--                  e.g. KFC Nigeria): the columns of Harlyy's Competitors page
--   brand          our brand (Domino's, Cold Stone Creamery, Pinkberry, ...) or the competitor brand
--   topic_group    Customer Service, Food & Beverage, Ambiance, Delivery Experience
--   topic          e.g. Staff Friendliness, Taste, Order Accuracy
--   sentiment      the sentence's: positive / neutral / negative (scores 0-1 alongside)
--   review_created_at / review_date: when the customer POSTED it (UTC / local day), never
--                  when Harlyy re-synced it.
-- Competitors are Google only; ours include Chowdeck (source tells them apart).

DROP VIEW IF EXISTS harlyy_feedback_analytics.vw_topic_mentions;

CREATE VIEW harlyy_feedback_analytics.vw_topic_mentions AS
SELECT 'Eat N''Go'                AS company,
       r.brand,
       r.country_code,
       r.source,
       r.listing_name,
       'review:' || r.review_id   AS review_key,
       r.review_created_at,
       r.review_date,
       r.rating,
       t.topic_group,
       t.topic,
       t.category_id,
       t.sentence_no,
       t.sentiment,
       t.score_positive,
       t.score_negative,
       t.score_neutral
FROM harlyy_feedback_analytics.review_topics t
JOIN harlyy_feedback_analytics.reviews r ON r.review_id = t.review_id
WHERE r.status = 'active'
UNION ALL
SELECT r.brand,
       r.brand,
       r.country_code,
       r.source,
       r.listing_name,
       'competitor:' || r.competitor_review_id,
       r.review_created_at,
       r.review_date,
       r.rating,
       t.topic_group,
       t.topic,
       t.category_id,
       t.sentence_no,
       t.sentiment,
       t.score_positive,
       t.score_negative,
       t.score_neutral
FROM harlyy_feedback_analytics.competitor_review_topics t
JOIN harlyy_feedback_analytics.competitor_reviews r ON r.competitor_review_id = t.competitor_review_id
WITH NO SCHEMA BINDING;

-- Readers need SELECT on the tables underneath as well (late-binding view):
-- GRANT SELECT ON harlyy_feedback_analytics.vw_topic_mentions, harlyy_feedback_analytics.review_topics,
--                 harlyy_feedback_analytics.reviews, harlyy_feedback_analytics.competitor_review_topics,
--                 harlyy_feedback_analytics.competitor_reviews TO <user>;
