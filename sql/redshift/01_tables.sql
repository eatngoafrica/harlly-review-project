CREATE SCHEMA IF NOT EXISTS harlyy_feedback_analytics;
CREATE SCHEMA IF NOT EXISTS harlyy_feedback_staging;

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.submissions (
    submission_id VARCHAR(128),
    survey_id VARCHAR(128),
    location_id VARCHAR(128),
    customer_id VARCHAR(128),
    staff_id VARCHAR(128),
    device_id VARCHAR(128),
    status VARCHAR(64),
    is_completed BOOLEAN,
    alert_sent BOOLEAN,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    last_answer_at TIMESTAMP,
    created_at_local TIMESTAMP,
    created_date DATE,
    created_hour INTEGER,
    weekday VARCHAR(64),
    duration_ms BIGINT,
    duration_min DOUBLE PRECISION,
    overall_rating INTEGER,
    rating_band VARCHAR(64),
    has_comment BOOLEAN,
    comment_text VARCHAR(65535),
    has_contact BOOLEAN,
    customer_name VARCHAR(512),
    customer_phone VARCHAR(64),
    PRIMARY KEY (submission_id)
)
DISTKEY (submission_id)
SORTKEY (created_date);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.submission_answers (
    submission_id VARCHAR(128),
    step_id VARCHAR(128),
    step_type VARCHAR(64),
    question VARCHAR(65535),
    metric_id VARCHAR(128),
    metric_name VARCHAR(512),
    answer VARCHAR(65535),
    answer_type VARCHAR(64),
    submitted_at TIMESTAMP,
    rating INTEGER,
    text VARCHAR(65535),
    name VARCHAR(512),
    phone_number VARCHAR(64),
    linked_rating INTEGER,
    metric_sentiment VARCHAR(64),
    smile_weight DOUBLE PRECISION,
    smile_points DOUBLE PRECISION
)
DISTKEY (submission_id)
SORTKEY (submission_id);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.incidents (
    incident_id VARCHAR(128),
    code VARCHAR(64),
    type VARCHAR(64),
    is_survey_incident BOOLEAN,
    status VARCHAR(64),
    is_open BOOLEAN,
    media_document_id VARCHAR(128),
    media_source_id VARCHAR(128),
    submission_id VARCHAR(128),
    survey_id VARCHAR(128),
    location_id VARCHAR(128),
    customer_id VARCHAR(128),
    staff_id VARCHAR(128),
    rating INTEGER,
    assignee_ids VARCHAR(4096),
    reviewed_by VARCHAR(128),
    resolved_by VARCHAR(128),
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    created_date DATE,
    reviewed_at TIMESTAMP,
    resolved_at TIMESTAMP,
    hours_to_review DOUBLE PRECISION,
    hours_to_resolve DOUBLE PRECISION,
    PRIMARY KEY (incident_id)
)
DISTSTYLE EVEN
SORTKEY (created_date);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.incident_metrics (
    incident_id VARCHAR(128),
    metric_id VARCHAR(128),
    metric_name VARCHAR(512)
)
DISTKEY (incident_id)
SORTKEY (incident_id);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.reviews (
    review_id VARCHAR(128),
    source VARCHAR(64),
    listing_id VARCHAR(128),
    listing_name VARCHAR(512),
    brand VARCHAR(512),
    location_id VARCHAR(128),
    country_code VARCHAR(64),
    city VARCHAR(512),
    source_review_id VARCHAR(512),
    source_url VARCHAR(2048),
    rating INTEGER,
    title VARCHAR(512),
    content VARCHAR(65535),
    customer_name VARCHAR(512),
    has_reply BOOLEAN,
    reply_content VARCHAR(65535),
    replied_at TIMESTAMP,
    sentiment VARCHAR(64),
    sentiment_positive DOUBLE PRECISION,
    sentiment_negative DOUBLE PRECISION,
    sentiment_neutral DOUBLE PRECISION,
    status VARCHAR(64),
    review_created_at TIMESTAMP,
    review_date DATE,
    updated_at TIMESTAMP,
    synced_at TIMESTAMP,
    received_at TIMESTAMP,
    alert_sent BOOLEAN,
    PRIMARY KEY (review_id)
)
DISTSTYLE EVEN
SORTKEY (review_date);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.locations (
    location_id VARCHAR(128),
    location_name VARCHAR(512),
    brand VARCHAR(512),
    country VARCHAR(512),
    state VARCHAR(512),
    city VARCHAR(512),
    region VARCHAR(512),
    regional_manager VARCHAR(512),
    order_type VARCHAR(512),
    other_labels VARCHAR(4096),
    is_online BOOLEAN,
    timezone VARCHAR(64),
    country_code VARCHAR(64),
    address_line1 VARCHAR(512),
    address_line2 VARCHAR(512),
    city_address VARCHAR(512),
    postcode VARCHAR(64),
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    google_place_id VARCHAR(512),
    status VARCHAR(64),
    updated_at TIMESTAMP,
    PRIMARY KEY (location_id)
)
DISTSTYLE ALL
SORTKEY (location_id);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.location_labels (
    location_id VARCHAR(128),
    label_id VARCHAR(128)
)
DISTSTYLE ALL
SORTKEY (location_id);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.labels (
    label_id VARCHAR(128),
    label_name VARCHAR(512),
    label_group VARCHAR(512),
    label_value VARCHAR(512),
    type VARCHAR(64),
    description VARCHAR(65535),
    status VARCHAR(64),
    PRIMARY KEY (label_id)
)
DISTSTYLE ALL
SORTKEY (label_id);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.surveys (
    survey_id VARCHAR(128),
    survey_name VARCHAR(512),
    brand VARCHAR(512),
    channel VARCHAR(64),
    survey_type VARCHAR(64),
    status VARCHAR(64),
    step_count INTEGER,
    created_at TIMESTAMP,
    PRIMARY KEY (survey_id)
)
DISTSTYLE ALL
SORTKEY (survey_id);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.survey_steps (
    step_id VARCHAR(128),
    survey_id VARCHAR(128),
    position INTEGER,
    step_type VARCHAR(64),
    question VARCHAR(65535),
    negative_question VARCHAR(65535),
    description VARCHAR(65535),
    follow_up_step_id VARCHAR(128),
    is_multi_select BOOLEAN,
    status VARCHAR(64),
    is_archived BOOLEAN,
    is_overall_rating BOOLEAN,
    PRIMARY KEY (step_id)
)
DISTSTYLE ALL
SORTKEY (step_id);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.step_options (
    step_id VARCHAR(128),
    metric_id VARCHAR(128),
    metric_name VARCHAR(512),
    option_order INTEGER
)
DISTSTYLE ALL
SORTKEY (step_id);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.metrics (
    metric_id VARCHAR(128),
    metric_name VARCHAR(512),
    description VARCHAR(65535),
    hide_from_analytics BOOLEAN,
    status VARCHAR(64),
    PRIMARY KEY (metric_id)
)
DISTSTYLE ALL
SORTKEY (metric_id);

CREATE TABLE IF NOT EXISTS harlyy_feedback_analytics.staff (
    staff_id VARCHAR(128),
    name VARCHAR(512),
    position VARCHAR(512),
    status VARCHAR(64),
    last_active_at TIMESTAMP,
    PRIMARY KEY (staff_id)
)
DISTSTYLE ALL
SORTKEY (staff_id);

-- Staging: the load job's own working copies, emptied at the start of every load.
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.submissions (LIKE harlyy_feedback_analytics.submissions);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.submission_answers (LIKE harlyy_feedback_analytics.submission_answers);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.incidents (LIKE harlyy_feedback_analytics.incidents);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.incident_metrics (LIKE harlyy_feedback_analytics.incident_metrics);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.reviews (LIKE harlyy_feedback_analytics.reviews);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.locations (LIKE harlyy_feedback_analytics.locations);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.location_labels (LIKE harlyy_feedback_analytics.location_labels);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.labels (LIKE harlyy_feedback_analytics.labels);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.surveys (LIKE harlyy_feedback_analytics.surveys);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.survey_steps (LIKE harlyy_feedback_analytics.survey_steps);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.step_options (LIKE harlyy_feedback_analytics.step_options);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.metrics (LIKE harlyy_feedback_analytics.metrics);
CREATE TABLE IF NOT EXISTS harlyy_feedback_staging.staff (LIKE harlyy_feedback_analytics.staff);

