-- One-off change, 25 Nov 2026: review topics, competitors, and Harlyy's incident rule.
-- Run in Redshift as the schema owner or an admin BEFORE deploying the new Glue scripts
-- (terraform apply): from then on every load writes these tables and columns, and a load
-- that finds them missing fails with "Table definitions do not match".
-- Same definitions as sql/redshift/01_tables.sql (generated from glue/harlyy_extract.py).
-- Safe to re-run except the two ADD COLUMN lines (they fail if the column already exists).
--
-- After deploying, run the extract once with --since 2026-09-01 (Glue job, Run with
-- parameters): it re-reads everything changed since then, filling the new tables
-- (competitors from Sep 2026) and the incident columns of incidents changed since.

-- 1. New incident columns (added at the end, as in TABLES).
ALTER TABLE harlyy_feedback_analytics.incidents ADD COLUMN is_actionable BOOLEAN;
ALTER TABLE harlyy_feedback_analytics.incidents ADD COLUMN counts_in_harlyy BOOLEAN;
-- Incidents already loaded: survey and review incidents always count in Harlyy's total.
-- (Photo / document incidents are set by the next extract that reads them; a catch-up
-- run from 1 Sep re-reads everything changed since then.)
UPDATE harlyy_feedback_analytics.incidents
SET counts_in_harlyy = type IN ('submission', 'review')
WHERE counts_in_harlyy IS NULL;
-- Staging copy: rebuilt from the target (the load empties it every run anyway).
DROP TABLE IF EXISTS harlyy_feedback_staging.incidents;
CREATE TABLE harlyy_feedback_staging.incidents (LIKE harlyy_feedback_analytics.incidents);

-- 2. New tables.
CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.review_topics (
    review_id VARCHAR(128),
    sentence_no INTEGER,
    category_id VARCHAR(128),
    topic VARCHAR(512),
    topic_group VARCHAR(512),
    sentiment VARCHAR(64),
    score_positive DOUBLE PRECISION,
    score_negative DOUBLE PRECISION,
    score_neutral DOUBLE PRECISION,
    sentence_offset INTEGER,
    sentence_length INTEGER
)
DISTKEY (review_id)
SORTKEY (review_id);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.competitor_reviews (
    competitor_review_id VARCHAR(128),
    competitor_listing_id VARCHAR(128),
    listing_name VARCHAR(512),
    brand_id VARCHAR(128),
    brand VARCHAR(512),
    country_code VARCHAR(64),
    source VARCHAR(64),
    source_review_id VARCHAR(512),
    source_url VARCHAR(2048),
    rating INTEGER,
    title VARCHAR(512),
    content VARCHAR(65535),
    has_reply BOOLEAN,
    reply_content VARCHAR(65535),
    replied_at TIMESTAMP,
    sentiment VARCHAR(64),
    sentiment_positive DOUBLE PRECISION,
    sentiment_negative DOUBLE PRECISION,
    sentiment_neutral DOUBLE PRECISION,
    review_created_at TIMESTAMP,
    review_date DATE,
    updated_at TIMESTAMP,
    synced_at TIMESTAMP,
    PRIMARY KEY (competitor_review_id)
)
DISTSTYLE EVEN
SORTKEY (review_date);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.competitor_review_topics (
    competitor_review_id VARCHAR(128),
    sentence_no INTEGER,
    category_id VARCHAR(128),
    topic VARCHAR(512),
    topic_group VARCHAR(512),
    sentiment VARCHAR(64),
    score_positive DOUBLE PRECISION,
    score_negative DOUBLE PRECISION,
    score_neutral DOUBLE PRECISION,
    sentence_offset INTEGER,
    sentence_length INTEGER
)
DISTKEY (competitor_review_id)
SORTKEY (competitor_review_id);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.review_categories (
    category_id VARCHAR(128),
    topic VARCHAR(512),
    topic_group VARCHAR(512),
    PRIMARY KEY (category_id)
)
DISTSTYLE ALL
SORTKEY (category_id);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.competitor_listings (
    competitor_listing_id VARCHAR(128),
    name VARCHAR(512),
    brand_id VARCHAR(128),
    brand VARCHAR(512),
    country_code VARCHAR(64),
    address VARCHAR(512),
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    source VARCHAR(64),
    source_place_id VARCHAR(512),
    source_url VARCHAR(2048),
    google_rating DOUBLE PRECISION,
    google_review_count INTEGER,
    is_active BOOLEAN,
    is_scraping BOOLEAN,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    synced_at TIMESTAMP,
    PRIMARY KEY (competitor_listing_id)
)
DISTSTYLE ALL
SORTKEY (competitor_listing_id);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.brands (
    brand_id VARCHAR(128),
    brand_name VARCHAR(512),
    website_url VARCHAR(2048),
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    PRIMARY KEY (brand_id)
)
DISTSTYLE ALL
SORTKEY (brand_id);

-- Staging copies.
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.review_topics (LIKE harlyy_feedback_analytics.review_topics);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.competitor_reviews (LIKE harlyy_feedback_analytics.competitor_reviews);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.competitor_review_topics (LIKE harlyy_feedback_analytics.competitor_review_topics);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.review_categories (LIKE harlyy_feedback_analytics.review_categories);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.competitor_listings (LIKE harlyy_feedback_analytics.competitor_listings);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.brands (LIKE harlyy_feedback_analytics.brands);

-- 3. The Glue role's access. Default privileges usually cover new tables, but only for
--    tables created by the user who set them, so grant explicitly.
GRANT SELECT, INSERT, UPDATE, DELETE ON harlyy_feedback_analytics.review_topics TO "IAMR:eatngo-harlyy-feedback-glue";
GRANT SELECT, INSERT, UPDATE, DELETE ON harlyy_feedback_analytics.competitor_reviews TO "IAMR:eatngo-harlyy-feedback-glue";
GRANT SELECT, INSERT, UPDATE, DELETE ON harlyy_feedback_analytics.competitor_review_topics TO "IAMR:eatngo-harlyy-feedback-glue";
GRANT SELECT, INSERT, UPDATE, DELETE ON harlyy_feedback_analytics.review_categories TO "IAMR:eatngo-harlyy-feedback-glue";
GRANT SELECT, INSERT, UPDATE, DELETE ON harlyy_feedback_analytics.competitor_listings TO "IAMR:eatngo-harlyy-feedback-glue";
GRANT SELECT, INSERT, UPDATE, DELETE ON harlyy_feedback_analytics.brands TO "IAMR:eatngo-harlyy-feedback-glue";
GRANT SELECT, INSERT, DELETE ON harlyy_feedback_staging.review_topics TO "IAMR:eatngo-harlyy-feedback-glue";
GRANT SELECT, INSERT, DELETE ON harlyy_feedback_staging.competitor_reviews TO "IAMR:eatngo-harlyy-feedback-glue";
GRANT SELECT, INSERT, DELETE ON harlyy_feedback_staging.competitor_review_topics TO "IAMR:eatngo-harlyy-feedback-glue";
GRANT SELECT, INSERT, DELETE ON harlyy_feedback_staging.review_categories TO "IAMR:eatngo-harlyy-feedback-glue";
GRANT SELECT, INSERT, DELETE ON harlyy_feedback_staging.competitor_listings TO "IAMR:eatngo-harlyy-feedback-glue";
GRANT SELECT, INSERT, DELETE ON harlyy_feedback_staging.brands TO "IAMR:eatngo-harlyy-feedback-glue";
GRANT SELECT, INSERT, DELETE ON harlyy_feedback_staging.incidents TO "IAMR:eatngo-harlyy-feedback-glue";

-- 4. Check: should list 6 tables, and incidents should end with the two new columns.
-- SELECT tablename FROM pg_tables WHERE schemaname = 'harlyy_feedback_analytics'
--   AND tablename IN ('review_topics', 'competitor_reviews', 'competitor_review_topics',
--                     'review_categories', 'competitor_listings', 'brands');
-- SELECT "column" FROM pg_table_def WHERE schemaname = 'harlyy_feedback_analytics'
--   AND tablename = 'incidents' ORDER BY 1;
