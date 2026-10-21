-- Run once as an admin, after 01_tables.sql, in the database the pipeline loads into.
--
-- The Glue jobs call the Redshift Data API with their IAM role, so Redshift sees them
-- as the database user "IAMR:<role name>". The role name is the glue_role_name output
-- of cloud_infra (default: eatngo-harlyy-feedback-glue).

CREATE USER "IAMR:eatngo-harlyy-feedback-glue" PASSWORD DISABLE;

-- Target: the load upserts and replaces rows; it never creates or drops tables.
GRANT USAGE ON SCHEMA harlyy_feedback_analytics TO "IAMR:eatngo-harlyy-feedback-glue";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA harlyy_feedback_analytics TO "IAMR:eatngo-harlyy-feedback-glue";

-- Staging: the load's own working copies.
GRANT USAGE ON SCHEMA harlyy_feedback_staging TO "IAMR:eatngo-harlyy-feedback-glue";
GRANT SELECT, INSERT, DELETE ON ALL TABLES IN SCHEMA harlyy_feedback_staging TO "IAMR:eatngo-harlyy-feedback-glue";

-- Tables added to harlyy_feedback_analytics later get the same access automatically.
ALTER DEFAULT PRIVILEGES IN SCHEMA harlyy_feedback_analytics
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "IAMR:eatngo-harlyy-feedback-glue";
ALTER DEFAULT PRIVILEGES IN SCHEMA harlyy_feedback_staging
    GRANT SELECT, INSERT, DELETE ON TABLES TO "IAMR:eatngo-harlyy-feedback-glue";

-- Analysts: read-only on the target schema. Replace analyst_role with your group or role.
-- GRANT USAGE ON SCHEMA harlyy_feedback_analytics TO ROLE analyst_role;
-- GRANT SELECT ON ALL TABLES IN SCHEMA harlyy_feedback_analytics TO ROLE analyst_role;
