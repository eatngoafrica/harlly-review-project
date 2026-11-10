-- Athena views over the Glue catalog database harlyy_feedback_lake: the newest copy of each record.
-- Generated: python glue/harlyy_extract.py --print-athena-views > sql/athena/latest_views.sql
-- The Athena console runs one statement at a time.

CREATE OR REPLACE VIEW harlyy_feedback_lake.latest_submissions AS
SELECT submission_id, survey_id, location_id, customer_id, staff_id, device_id, status, is_completed, alert_sent, created_at, updated_at, last_answer_at, created_at_local, created_date, created_hour, weekday, duration_ms, duration_min, overall_rating, rating_band, has_comment, comment_text, has_contact, customer_name, customer_phone
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY submission_id ORDER BY business_date DESC, CASE "hour" WHEN 'full' THEN -1 WHEN 'day' THEN 24 ELSE CAST("hour" AS INTEGER) END DESC) AS version
    FROM harlyy_feedback_lake.submissions
)
WHERE version = 1;

CREATE OR REPLACE VIEW harlyy_feedback_lake.latest_submission_answers AS
SELECT c.submission_id, c.step_id, c.step_type, c.question, c.metric_id, c.metric_name, c.answer, c.answer_type, c.submitted_at, c.rating, c.text, c.name, c.phone_number, c.linked_rating, c.metric_sentiment, c.smile_weight, c.smile_points
FROM harlyy_feedback_lake.submission_answers c
JOIN (
    SELECT submission_id, business_date, "hour",
           ROW_NUMBER() OVER (PARTITION BY submission_id ORDER BY business_date DESC, CASE "hour" WHEN 'full' THEN -1 WHEN 'day' THEN 24 ELSE CAST("hour" AS INTEGER) END DESC) AS version
    FROM harlyy_feedback_lake.submissions
) p ON p.version = 1 AND p.submission_id = c.submission_id
     AND p.business_date = c.business_date AND p."hour" = c."hour";

CREATE OR REPLACE VIEW harlyy_feedback_lake.latest_incidents AS
SELECT incident_id, code, type, is_survey_incident, status, is_open, media_document_id, media_source_id, submission_id, survey_id, location_id, customer_id, staff_id, rating, assignee_ids, reviewed_by, resolved_by, created_at, updated_at, created_date, reviewed_at, resolved_at, hours_to_review, hours_to_resolve
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY incident_id ORDER BY business_date DESC, CASE "hour" WHEN 'full' THEN -1 WHEN 'day' THEN 24 ELSE CAST("hour" AS INTEGER) END DESC) AS version
    FROM harlyy_feedback_lake.incidents
)
WHERE version = 1;

CREATE OR REPLACE VIEW harlyy_feedback_lake.latest_incident_metrics AS
SELECT c.incident_id, c.metric_id, c.metric_name
FROM harlyy_feedback_lake.incident_metrics c
JOIN (
    SELECT incident_id, business_date, "hour",
           ROW_NUMBER() OVER (PARTITION BY incident_id ORDER BY business_date DESC, CASE "hour" WHEN 'full' THEN -1 WHEN 'day' THEN 24 ELSE CAST("hour" AS INTEGER) END DESC) AS version
    FROM harlyy_feedback_lake.incidents
) p ON p.version = 1 AND p.incident_id = c.incident_id
     AND p.business_date = c.business_date AND p."hour" = c."hour";

CREATE OR REPLACE VIEW harlyy_feedback_lake.latest_reviews AS
SELECT review_id, source, listing_id, listing_name, brand, location_id, country_code, city, source_review_id, source_url, rating, title, content, customer_name, has_reply, reply_content, replied_at, sentiment, sentiment_positive, sentiment_negative, sentiment_neutral, status, review_created_at, review_date, updated_at, synced_at, received_at, alert_sent
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY review_id ORDER BY business_date DESC, CASE "hour" WHEN 'full' THEN -1 WHEN 'day' THEN 24 ELSE CAST("hour" AS INTEGER) END DESC) AS version
    FROM harlyy_feedback_lake.reviews
)
WHERE version = 1;

CREATE OR REPLACE VIEW harlyy_feedback_lake.latest_locations AS
SELECT location_id, location_name, brand, country, state, city, region, regional_manager, order_type, other_labels, is_online, timezone, country_code, address_line1, address_line2, city_address, postcode, latitude, longitude, google_place_id, status, updated_at
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY location_id ORDER BY business_date DESC, CASE "hour" WHEN 'full' THEN -1 WHEN 'day' THEN 24 ELSE CAST("hour" AS INTEGER) END DESC) AS version
    FROM harlyy_feedback_lake.locations
)
WHERE version = 1;

CREATE OR REPLACE VIEW harlyy_feedback_lake.latest_location_labels AS
SELECT c.location_id, c.label_id
FROM harlyy_feedback_lake.location_labels c
JOIN (
    SELECT location_id, business_date, "hour",
           ROW_NUMBER() OVER (PARTITION BY location_id ORDER BY business_date DESC, CASE "hour" WHEN 'full' THEN -1 WHEN 'day' THEN 24 ELSE CAST("hour" AS INTEGER) END DESC) AS version
    FROM harlyy_feedback_lake.locations
) p ON p.version = 1 AND p.location_id = c.location_id
     AND p.business_date = c.business_date AND p."hour" = c."hour";

CREATE OR REPLACE VIEW harlyy_feedback_lake.latest_labels AS
SELECT label_id, label_name, label_group, label_value, type, description, status
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY label_id ORDER BY business_date DESC, CASE "hour" WHEN 'full' THEN -1 WHEN 'day' THEN 24 ELSE CAST("hour" AS INTEGER) END DESC) AS version
    FROM harlyy_feedback_lake.labels
)
WHERE version = 1;

CREATE OR REPLACE VIEW harlyy_feedback_lake.latest_surveys AS
SELECT survey_id, survey_name, brand, channel, survey_type, status, step_count, created_at
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY survey_id ORDER BY business_date DESC, CASE "hour" WHEN 'full' THEN -1 WHEN 'day' THEN 24 ELSE CAST("hour" AS INTEGER) END DESC) AS version
    FROM harlyy_feedback_lake.surveys
)
WHERE version = 1;

CREATE OR REPLACE VIEW harlyy_feedback_lake.latest_survey_steps AS
SELECT step_id, survey_id, position, step_type, question, negative_question, description, follow_up_step_id, is_multi_select, status, is_archived, is_overall_rating
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY step_id ORDER BY business_date DESC, CASE "hour" WHEN 'full' THEN -1 WHEN 'day' THEN 24 ELSE CAST("hour" AS INTEGER) END DESC) AS version
    FROM harlyy_feedback_lake.survey_steps
)
WHERE version = 1;

CREATE OR REPLACE VIEW harlyy_feedback_lake.latest_step_options AS
SELECT c.step_id, c.metric_id, c.metric_name, c.option_order
FROM harlyy_feedback_lake.step_options c
JOIN (
    SELECT step_id, business_date, "hour",
           ROW_NUMBER() OVER (PARTITION BY step_id ORDER BY business_date DESC, CASE "hour" WHEN 'full' THEN -1 WHEN 'day' THEN 24 ELSE CAST("hour" AS INTEGER) END DESC) AS version
    FROM harlyy_feedback_lake.survey_steps
) p ON p.version = 1 AND p.step_id = c.step_id
     AND p.business_date = c.business_date AND p."hour" = c."hour";

CREATE OR REPLACE VIEW harlyy_feedback_lake.latest_metrics AS
SELECT metric_id, metric_name, description, hide_from_analytics, status
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY metric_id ORDER BY business_date DESC, CASE "hour" WHEN 'full' THEN -1 WHEN 'day' THEN 24 ELSE CAST("hour" AS INTEGER) END DESC) AS version
    FROM harlyy_feedback_lake.metrics
)
WHERE version = 1;

CREATE OR REPLACE VIEW harlyy_feedback_lake.latest_staff AS
SELECT staff_id, name, position, status, last_active_at
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY staff_id ORDER BY business_date DESC, CASE "hour" WHEN 'full' THEN -1 WHEN 'day' THEN 24 ELSE CAST("hour" AS INTEGER) END DESC) AS version
    FROM harlyy_feedback_lake.staff
)
WHERE version = 1;

