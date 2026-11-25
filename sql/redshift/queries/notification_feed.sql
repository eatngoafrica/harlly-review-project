/*
Notification feed for business units and management: negative (1-2 star) customer
feedback from the last 30 days, from both sources:
  - Harlyy surveys       (submissions: Dine-In / Delivery, Website left out; completed
                          surveys, plus abandoned ones with a written comment. Abandoned
                          star-only surveys, where the customer tapped a rating and left,
                          are skipped even though Harlyy keeps the rating and may raise
                          an incident for them)
  - Google / Chowdeck    (reviews)

Recency is judged by when the CUSTOMER posted it, never by when it reached Redshift:
  surveys  submissions.created_at
  reviews  reviews.review_created_at  (the Google posting date)
Harlyy re-syncs old Google reviews in bulk (some from 2021-2025). They arrive as new
rows with a fresh updated_at / synced_at but keep their real posting date, so the
window below leaves them out.

Columns are the original app query's, in the same order; four are added at the end:
  source     survey / google / chowdeck
  review_id  for reviews (submission_id is blank for them)
  alert_id   unique key for every row ("survey:<id>" / "review:<id>"). The app should
             record each alert_id it sends and skip it next time, so nothing is sent twice.
  link       the review on Google / Chowdeck (blank for surveys)

For reviews: incident = blank, incident_status = 'replied' / 'not replied',
waiting = 'Waiting' while not replied, hours_to_pick_up = hours to our reply (or so far).
To change the window, edit days in params. With 30 days the same complaint is returned
on every run for a month, so the app's alert_id sent log is what stops repeat sends.
*/
with params as (
    select 30 as days
),
surveys as (
    select s.submission_id,
           sv.survey_name,
           sv.channel,
           coalesce(l.brand, sv.brand)                        as brand,
           coalesce(l.country_code, 'NG')                     as country_code,
           coalesce(sm.store_number, nf.store_number)         as store_number,
           s.created_at,
           s.created_at_local,
           s.overall_rating                                   as rating,
           nullif(trim(s.comment_text), '')                   as comment,
           nullif(trim(s.customer_name), '')                  as customer_name,
           nullif(trim(s.customer_phone), '')                 as customer_phone
      from harlyy_feedback_analytics.submissions s
      join harlyy_feedback_analytics.surveys sv            on sv.survey_id = s.survey_id
      left join harlyy_feedback_analytics.locations l      on l.location_id = s.location_id
      left join harlyy_feedback_analytics.vw_store_map sm  on sm.map_key = 'location:' || s.location_id
      left join harlyy_feedback_analytics.vw_negative_feedback nf
             on nf.alert_id = 'survey:' || s.submission_id
     cross join params p
     where sv.channel <> 'Website'
       and (s.is_completed                                              -- finished the survey,
            or nullif(trim(s.comment_text), '') is not null)            -- or left a written complaint
       and s.overall_rating in (1, 2)
       and s.created_at >= dateadd(day, -p.days, getdate())            -- posted recently
),
reviews as (
    select r.review_id,
           r.source,                                                     -- google / chowdeck
           r.listing_name,
           r.brand,
           coalesce(l.country_code, r.country_code, 'NG')     as country_code,
           sm.store_number,
           r.review_created_at                                as created_at,
           dateadd(hour, case when coalesce(l.country_code, r.country_code) = 'KE' then 3 else 1 end,
                   r.review_created_at)                       as created_at_local,
           r.rating,
           nullif(trim(r.content), '')                        as comment,
           nullif(trim(r.customer_name), '')                  as customer_name,
           r.has_reply,
           r.replied_at,
           r.source_url
      from harlyy_feedback_analytics.reviews r
      left join harlyy_feedback_analytics.locations l      on l.location_id = r.location_id
      left join harlyy_feedback_analytics.vw_store_map sm
             on sm.map_key = case when r.location_id is not null then 'location:' || r.location_id
                                  else 'listing:' || r.listing_id end
     cross join params p
     where r.status = 'active'
       and r.rating in (1, 2)
       and r.review_created_at >= dateadd(day, -p.days, getdate())     -- posted on Google recently
),
improve as (
    select a.submission_id,
           listagg(distinct a.metric_name, ', ') within group (order by a.metric_name) as want_improved
      from harlyy_feedback_analytics.submission_answers a
      join surveys u on u.submission_id = a.submission_id
     where a.step_type = 'metrics'
       and a.metric_name is not null
       and (   lower(regexp_replace(trim(a.question), '[[:space:]]+', ' ')) like 'what can we improve%'
            or lower(regexp_replace(trim(a.question), '[[:space:]]+', ' ')) like 'what was wrong with the order%'
            or lower(regexp_replace(trim(a.question), '[[:space:]]+', ' ')) like 'can you let us know more about the rider%')
     group by 1
),
latest_incident as (
    select submission_id, code, status, created_at, reviewed_at, resolved_at,
           row_number() over (partition by submission_id order by created_at desc) as n
      from harlyy_feedback_analytics.incidents
     where is_survey_incident
),
stores as (
    select store_number,
           max(store_name)  as store_name,
           max(area)        as area,
           max(regional_bu) as business_unit
      from public.pulse_store_master_map
     group by 1
),
feed as (
    -- Surveys
    select u.submission_id,
           u.created_at_local                                      as local_time,
           u.channel,
           u.store_number,
           st.store_name,
           u.brand,
           st.area,
           st.business_unit,
           u.rating,
           case u.rating when 1 then 'Terrible' when 2 then 'Poor' end as rating_label,
           coalesce(u.comment, 'No comment left.')                 as what_they_said,
           i.want_improved,
           u.customer_name,
           u.customer_phone,
           li.code                                                 as incident,
           coalesce(li.status, 'no incident')                      as incident_status,
           case when li.status = 'open' then 'Waiting' else '' end as waiting,
           round(datediff(minute, li.created_at, coalesce(li.reviewed_at, getdate())) / 60.0, 1)
                                                                   as hours_to_pick_up,
           'survey'                                                as source,
           cast(null as varchar(128))                              as review_id,
           'survey:' || u.submission_id                            as alert_id,
           cast(null as varchar(2048))                             as link,
           u.created_at                                            as sort_time
      from surveys u
      left join improve i          on i.submission_id = u.submission_id
      left join latest_incident li on li.submission_id = u.submission_id and li.n = 1
      left join stores st          on st.store_number = u.store_number
     where u.store_number is not null
    union all
    -- Google / Chowdeck reviews
    select cast(null as varchar(128)),
           r.created_at_local,
           initcap(r.source),                                      -- Google / Chowdeck
           r.store_number,
           coalesce(st.store_name, r.listing_name),
           r.brand,
           st.area,
           st.business_unit,
           r.rating,
           case r.rating when 1 then 'Terrible' when 2 then 'Poor' end,
           coalesce(r.comment, 'No comment left.'),
           cast(null as varchar(65535)),
           r.customer_name,
           cast(null as varchar(64)),                              -- reviews carry no phone
           cast(null as varchar(64)),
           case when r.has_reply then 'replied' else 'not replied' end,
           case when r.has_reply then '' else 'Waiting' end,
           round(datediff(minute, r.created_at, coalesce(r.replied_at, getdate())) / 60.0, 1),
           r.source,
           r.review_id,
           'review:' || r.review_id,
           r.source_url,
           r.created_at
      from reviews r
      left join stores st on st.store_number = r.store_number
     where r.store_number is not null
)
select submission_id, local_time, channel, store_number, store_name, brand, area, business_unit,
       rating, rating_label, what_they_said, want_improved, customer_name, customer_phone,
       incident, incident_status, waiting, hours_to_pick_up,
       source, review_id, alert_id, link
  from feed
 order by case when waiting = 'Waiting' then 0 else 1 end,
          sort_time desc
 limit 80;
