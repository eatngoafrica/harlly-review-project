-- One-off change, 16 Nov 2026: staff notes on incidents (incident_comments).
-- Run in Redshift as the schema owner or an admin BEFORE deploying the new Glue scripts
-- (terraform apply): from then on every load writes this table, and a load that finds it
-- missing fails with "Table definitions do not match".
-- Same definition as sql/redshift/01_tables.sql (generated from glue/harlyy_extract.py).

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.incident_comments (
    comment_id VARCHAR(128),
    incident_id VARCHAR(128),
    staff_id VARCHAR(128),
    content VARCHAR(65535),
    is_resolution_note BOOLEAN,
    attachment_count INTEGER,
    created_at TIMESTAMP,
    updated_at TIMESTAMP
)
DISTKEY (incident_id)
SORTKEY (incident_id);

CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.incident_comments (LIKE harlyy_feedback_analytics.incident_comments);

-- The pipeline's database user (02_grants.sql). Explicit, in case default privileges
-- were set up by a different user than the one running this.
GRANT SELECT, INSERT, UPDATE, DELETE ON harlyy_feedback_analytics.incident_comments TO "IAMR:eatngo-harlyy-feedback-glue";
GRANT SELECT, INSERT, DELETE ON harlyy_feedback_staging.incident_comments TO "IAMR:eatngo-harlyy-feedback-glue";

-- Analysts who read the other tables (add other users or roles as needed):
GRANT SELECT ON harlyy_feedback_analytics.incident_comments TO lawal_ayobola;

-- Check: should list the table in both schemas.
SELECT schemaname, tablename, tableowner
FROM pg_tables
WHERE tablename = 'incident_comments';
