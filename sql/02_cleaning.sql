/* ============================================================================
   FILE     : 02_cleaning.sql
   PROJECT  : Zomato Delivery Operations Analytics
   PURPOSE  : Load the raw CSV, profile and repair it, then populate the
              normalised star schema created in 01_schema.sql.
   ENGINE   : PostgreSQL 13+
   RUN      : psql -d zomato_ops -f 02_cleaning.sql
   ----------------------------------------------------------------------------
   DEFECTS FOUND DURING PROFILING (all repaired below, all logged to dq_audit)

   D1  Literal 'NaN' strings used as the null token in 7 columns
       (age 1,854 | ratings 1,908 | weather 616 | traffic 601 |
        multiple_deliveries 993 | festival 228 | city 1,200)
   D2  Three incompatible clock formats in the same column:
         'HH:MM'          -> normal
         '0.458333333'    -> Excel serial fraction of a day (= 11:00)
         '24:05:00'       -> hour-24 overflow, i.e. 00:05 the next day
   D3  ~8% of rows carry coordinates of 0.00 / 0.01 — GPS dropouts, not
       locations in the Gulf of Guinea
   D4  431 restaurant latitudes and 162 longitudes are sign-flipped
       (negative values for a dataset that is entirely within India)
   D5  53 delivery-partner ratings above the 5.0 maximum (max observed 6.0)
   D6  38 partner ages below 18 — below the legal minimum for the role
   D7  Order_Date arrives as DD-MM-YYYY text, which PostgreSQL will silently
       misread under the default MDY DateStyle

   PRINCIPLE: nothing is deleted. Bad values are nulled and the row is tagged
   (has_valid_geo, has_valid_times) so every downstream query can decide for
   itself whether to include it. Silent row-dropping is how analyses quietly
   become wrong.
   ========================================================================== */

SET DateStyle = 'ISO, DMY';   -- fixes D7 for the whole session


-- ###########################################################################
-- STEP 1 — LOAD THE RAW FILE
-- ###########################################################################
-- Edit the path below to point at your copy of the file, then run.
-- \copy is a psql client command (no server-side file permissions needed).

TRUNCATE staging.stg_deliveries;

\copy staging.stg_deliveries FROM 'Zomato_Dataset.csv' WITH (FORMAT csv, HEADER true)

\echo '--- rows landed in staging ---'
SELECT COUNT(*) AS rows_loaded FROM staging.stg_deliveries;


-- ###########################################################################
-- STEP 2 — HELPER FUNCTIONS
-- ###########################################################################

/* -----------------------------------------------------------------------
   core.parse_clock() — repairs defect D2.
   Returns an INTERVAL measured from midnight, so an input of '24:05:00'
   comes back as 24h05m and the caller can roll it onto the next date.
   ----------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.parse_clock(raw TEXT)
RETURNS INTERVAL
LANGUAGE plpgsql IMMUTABLE AS
$$
DECLARE
    txt TEXT := NULLIF(TRIM(COALESCE(raw, '')), '');
    hh  INT;
    mm  INT;
BEGIN
    IF txt IS NULL OR txt = 'NaN' THEN
        RETURN NULL;
    END IF;

    -- Format A: HH:MM or HH:MM:SS (hour may legitimately be 24 or 25)
    IF txt ~ '^\d{1,2}:\d{2}(:\d{2})?$' THEN
        hh := SPLIT_PART(txt, ':', 1)::INT;
        mm := SPLIT_PART(txt, ':', 2)::INT;
        IF mm > 59 THEN
            RETURN NULL;                       -- unrecoverable
        END IF;
        RETURN MAKE_INTERVAL(hours => hh, mins => mm);
    END IF;

    -- Format B: Excel serial fraction of a day ('0.458333333', '1')
    IF txt ~ '^(0?\.\d+|0|1(\.0+)?)$' THEN
        RETURN MAKE_INTERVAL(secs => ROUND(txt::NUMERIC * 86400)::INT);
    END IF;

    RETURN NULL;                               -- unrecognised format
END;
$$;

/* -----------------------------------------------------------------------
   core.haversine_km() — great-circle distance between two lat/long pairs.
   Used to derive the drop distance, which the source file does not supply
   but which is the single most important explanatory variable in the model.
   ----------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.haversine_km(
    lat1 NUMERIC, lon1 NUMERIC, lat2 NUMERIC, lon2 NUMERIC
) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS
$$
    SELECT ROUND(
        (2 * 6371 * ASIN(SQRT(
              POWER(SIN(RADIANS(lat2 - lat1) / 2), 2)
            + COS(RADIANS(lat1)) * COS(RADIANS(lat2))
            * POWER(SIN(RADIANS(lon2 - lon1) / 2), 2)
        )))::NUMERIC, 2)
    WHERE lat1 IS NOT NULL AND lon1 IS NOT NULL
      AND lat2 IS NOT NULL AND lon2 IS NOT NULL;
$$;

/* -----------------------------------------------------------------------
   core.clean_num() — strips the 'NaN' token (D1) and casts safely.
   ----------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.clean_num(raw TEXT)
RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS
$$
    SELECT CASE
        WHEN NULLIF(TRIM(COALESCE(raw,'')),'') IS NULL THEN NULL
        WHEN TRIM(raw) = 'NaN'                         THEN NULL
        WHEN TRIM(raw) ~ '^-?\d+(\.\d+)?$'             THEN TRIM(raw)::NUMERIC
        ELSE NULL
    END;
$$;

/* -----------------------------------------------------------------------
   core.clean_txt() — same, for categorical columns.
   ----------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.clean_txt(raw TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS
$$
    SELECT CASE
        WHEN NULLIF(TRIM(COALESCE(raw,'')),'') IS NULL THEN NULL
        WHEN TRIM(raw) IN ('NaN','nan','NA','')        THEN NULL
        ELSE TRIM(raw)
    END;
$$;


-- ###########################################################################
-- STEP 3 — THE CLEANING VIEW
--          One place where every repair is expressed. Downstream loads read
--          only from here, never from staging directly.
-- ###########################################################################

CREATE OR REPLACE VIEW staging.v_clean AS
WITH parsed AS (
    SELECT
        s.id                                                    AS order_id,
        core.clean_txt(s.delivery_person_id)                    AS partner_code,

        -- Shred the composite business key ---------------------------------
        SUBSTRING(s.delivery_person_id FROM '^([A-Z]+)RES')     AS city_code,
        SUBSTRING(s.delivery_person_id FROM '^([A-Z]+RES\d+)DEL') AS restaurant_code,

        -- D5 / D6: range-check the partner attributes ----------------------
        CASE WHEN core.clean_num(s.delivery_person_age) BETWEEN 18 AND 65
             THEN core.clean_num(s.delivery_person_age) END     AS partner_age,
        CASE WHEN core.clean_num(s.delivery_person_ratings) BETWEEN 1 AND 5
             THEN core.clean_num(s.delivery_person_ratings) END AS partner_rating,

        -- D3 / D4: unflip the sign, then reject GPS dropouts ---------------
        CASE WHEN ABS(core.clean_num(s.restaurant_latitude))  > 1
             THEN ABS(core.clean_num(s.restaurant_latitude))  END AS rest_lat,
        CASE WHEN ABS(core.clean_num(s.restaurant_longitude)) > 1
             THEN ABS(core.clean_num(s.restaurant_longitude)) END AS rest_lon,
        CASE WHEN ABS(core.clean_num(s.delivery_location_latitude))  > 1
             THEN ABS(core.clean_num(s.delivery_location_latitude))  END AS drop_lat,
        CASE WHEN ABS(core.clean_num(s.delivery_location_longitude)) > 1
             THEN ABS(core.clean_num(s.delivery_location_longitude)) END AS drop_lon,

        -- D7: explicit DD-MM-YYYY parse, never left to DateStyle -----------
        TO_DATE(TRIM(s.order_date), 'DD-MM-YYYY')               AS order_date,

        -- D2: mixed clock formats ------------------------------------------
        core.parse_clock(s.time_ordered)                        AS ordered_iv,
        core.parse_clock(s.time_order_picked)                   AS picked_iv,

        -- D1: categoricals --------------------------------------------------
        core.clean_txt(s.weather_conditions)                    AS weather_conditions,
        core.clean_txt(s.road_traffic_density)                  AS road_traffic_density,
        core.clean_num(s.vehicle_condition)::SMALLINT           AS vehicle_condition,
        core.clean_txt(s.type_of_order)                         AS type_of_order,
        core.clean_txt(s.type_of_vehicle)                       AS type_of_vehicle,
        core.clean_num(s.multiple_deliveries)::SMALLINT         AS multiple_deliveries,
        core.clean_txt(s.festival)                              AS festival,
        COALESCE(core.clean_txt(s.city), 'Unknown')             AS city_type,
        core.clean_num(s.time_taken_min)::SMALLINT              AS time_taken_min
    FROM staging.stg_deliveries s
),
timed AS (
    SELECT
        p.*,
        (p.order_date + p.ordered_iv) AS order_ts_raw,
        (p.order_date + p.picked_iv)  AS pickup_ts_raw
    FROM parsed p
)
SELECT
    t.order_id,
    t.partner_code,
    t.city_code,
    t.restaurant_code,
    t.partner_age::SMALLINT,
    t.partner_rating,
    t.rest_lat, t.rest_lon, t.drop_lat, t.drop_lon,
    t.order_date,
    t.order_ts_raw   AS order_ts,

    -- If pickup lands before the order, the pickup rolled past midnight.
    CASE WHEN t.pickup_ts_raw IS NOT NULL
              AND t.order_ts_raw IS NOT NULL
              AND t.pickup_ts_raw < t.order_ts_raw
         THEN t.pickup_ts_raw + INTERVAL '1 day'
         ELSE t.pickup_ts_raw
    END                                                          AS pickup_ts,

    t.weather_conditions,
    t.road_traffic_density,
    t.vehicle_condition,
    t.type_of_order,
    t.type_of_vehicle,
    t.multiple_deliveries,
    (t.festival = 'Yes')                                         AS is_festival,
    t.city_type,
    t.time_taken_min,
    core.haversine_km(t.rest_lat, t.rest_lon, t.drop_lat, t.drop_lon) AS distance_km,
    (t.rest_lat IS NOT NULL AND t.drop_lat IS NOT NULL)          AS has_valid_geo,
    (t.ordered_iv IS NOT NULL AND t.picked_iv IS NOT NULL)       AS has_valid_times
FROM timed t;


-- ###########################################################################
-- STEP 4 — DATA-QUALITY AUDIT
--          Quantify every defect before repairing it. These numbers go
--          straight into the README and the presentation.
-- ###########################################################################

TRUNCATE core.dq_audit RESTART IDENTITY;

INSERT INTO core.dq_audit (check_name, rows_flagged, rows_total, action_taken)
SELECT 'D1  age = NaN',
       COUNT(*) FILTER (WHERE TRIM(delivery_person_age) = 'NaN'),
       COUNT(*), 'Set NULL; partner age excluded from age-band analysis'
FROM staging.stg_deliveries
UNION ALL
SELECT 'D1  rating = NaN',
       COUNT(*) FILTER (WHERE TRIM(delivery_person_ratings) = 'NaN'),
       COUNT(*), 'Set NULL'
FROM staging.stg_deliveries
UNION ALL
SELECT 'D1  traffic density = NaN',
       COUNT(*) FILTER (WHERE TRIM(road_traffic_density) = 'NaN'),
       COUNT(*), 'Set NULL; excluded from traffic segmentation'
FROM staging.stg_deliveries
UNION ALL
SELECT 'D1  weather = NaN',
       COUNT(*) FILTER (WHERE TRIM(weather_conditions) = 'NaN'),
       COUNT(*), 'Set NULL'
FROM staging.stg_deliveries
UNION ALL
SELECT 'D1  city class = NaN',
       COUNT(*) FILTER (WHERE TRIM(city) = 'NaN'),
       COUNT(*), 'Mapped to ''Unknown'' so rows survive the SLA join'
FROM staging.stg_deliveries
UNION ALL
SELECT 'D2  non HH:MM order time',
       COUNT(*) FILTER (WHERE TRIM(time_ordered) !~ '^\d{1,2}:\d{2}$'
                          AND TRIM(time_ordered) <> 'NaN'),
       COUNT(*), 'Excel serial fractions converted via parse_clock()'
FROM staging.stg_deliveries
UNION ALL
SELECT 'D2  hour-24 overflow on pickup',
       COUNT(*) FILTER (WHERE TRIM(time_order_picked) ~ '^2[4-9]:'),
       COUNT(*), 'Rolled onto the following calendar day'
FROM staging.stg_deliveries
UNION ALL
SELECT 'D3  GPS dropout (coordinate ~ 0)',
       COUNT(*) FILTER (WHERE ABS(core.clean_num(restaurant_latitude)) < 1),
       COUNT(*), 'Coordinates nulled; row kept, has_valid_geo = FALSE'
FROM staging.stg_deliveries
UNION ALL
SELECT 'D4  sign-flipped latitude',
       COUNT(*) FILTER (WHERE core.clean_num(restaurant_latitude) < 0),
       COUNT(*), 'ABS() applied — dataset is wholly within India'
FROM staging.stg_deliveries
UNION ALL
SELECT 'D5  rating above 5.0 ceiling',
       COUNT(*) FILTER (WHERE core.clean_num(delivery_person_ratings) > 5),
       COUNT(*), 'Set NULL — outside the valid 1.0–5.0 scale'
FROM staging.stg_deliveries
UNION ALL
SELECT 'D6  partner age below 18',
       COUNT(*) FILTER (WHERE core.clean_num(delivery_person_age) < 18),
       COUNT(*), 'Set NULL — below legal working age'
FROM staging.stg_deliveries;

\echo '--- data quality audit ---'
SELECT check_name, rows_flagged, pct_flagged, action_taken FROM core.dq_audit ORDER BY check_id;


-- ###########################################################################
-- STEP 5 — POPULATE THE DIMENSIONS
-- ###########################################################################

-- 5.1 dim_city -------------------------------------------------------------
INSERT INTO core.dim_city (city_code, city_name, city_tier)
SELECT DISTINCT
    c.city_code,
    CASE c.city_code
        WHEN 'AGR'    THEN 'Agra'        WHEN 'ALH'    THEN 'Prayagraj'
        WHEN 'AURG'   THEN 'Aurangabad'  WHEN 'BANG'   THEN 'Bengaluru'
        WHEN 'BHP'    THEN 'Bhopal'      WHEN 'CHEN'   THEN 'Chennai'
        WHEN 'COIMB'  THEN 'Coimbatore'  WHEN 'DEH'    THEN 'Dehradun'
        WHEN 'GOA'    THEN 'Goa'         WHEN 'HYD'    THEN 'Hyderabad'
        WHEN 'INDO'   THEN 'Indore'      WHEN 'JAP'    THEN 'Jaipur'
        WHEN 'KNP'    THEN 'Kanpur'      WHEN 'KOC'    THEN 'Kochi'
        WHEN 'KOL'    THEN 'Kolkata'     WHEN 'LUDH'   THEN 'Ludhiana'
        WHEN 'MUM'    THEN 'Mumbai'      WHEN 'MYS'    THEN 'Mysuru'
        WHEN 'PUNE'   THEN 'Pune'        WHEN 'RANCHI' THEN 'Ranchi'
        WHEN 'SUR'    THEN 'Surat'       WHEN 'VAD'    THEN 'Vadodara'
        ELSE c.city_code
    END,
    CASE WHEN c.city_code IN ('MUM','BANG','HYD','CHEN','KOL','PUNE')
         THEN 1 ELSE 2 END
FROM staging.v_clean c
WHERE c.city_code IS NOT NULL;

-- 5.2 dim_restaurant -------------------------------------------------------
--     Hub coordinates = median of the valid pickup points for that hub.
--     Median, not mean, so any surviving outlier cannot drag the location.
INSERT INTO core.dim_restaurant (restaurant_code, city_id, hub_latitude, hub_longitude)
SELECT
    v.restaurant_code,
    d.city_id,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v.rest_lat)::NUMERIC(9,6),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v.rest_lon)::NUMERIC(9,6)
FROM staging.v_clean v
JOIN core.dim_city d ON d.city_code = v.city_code
WHERE v.restaurant_code IS NOT NULL
GROUP BY v.restaurant_code, d.city_id;

-- 5.3 dim_partner ----------------------------------------------------------
--     A partner's age / rating / vehicle repeat on every one of their orders.
--     MODE() collapses them to the single most frequent value, which is more
--     robust than MAX() or an arbitrary FIRST.
INSERT INTO core.dim_partner (
    partner_code, restaurant_id, city_id,
    partner_age, partner_rating, primary_vehicle, age_band, rating_band
)
SELECT
    v.partner_code,
    r.restaurant_id,
    r.city_id,
    MODE() WITHIN GROUP (ORDER BY v.partner_age)      AS partner_age,
    MODE() WITHIN GROUP (ORDER BY v.partner_rating)   AS partner_rating,
    MODE() WITHIN GROUP (ORDER BY v.type_of_vehicle)  AS primary_vehicle,
    CASE
        WHEN MODE() WITHIN GROUP (ORDER BY v.partner_age) < 25 THEN '18-24'
        WHEN MODE() WITHIN GROUP (ORDER BY v.partner_age) < 31 THEN '25-30'
        WHEN MODE() WITHIN GROUP (ORDER BY v.partner_age) < 36 THEN '31-35'
        WHEN MODE() WITHIN GROUP (ORDER BY v.partner_age) IS NULL THEN 'Unknown'
        ELSE '36+'
    END,
    CASE
        WHEN MODE() WITHIN GROUP (ORDER BY v.partner_rating) IS NULL  THEN 'Unrated'
        WHEN MODE() WITHIN GROUP (ORDER BY v.partner_rating) >= 4.8   THEN 'Excellent (4.8+)'
        WHEN MODE() WITHIN GROUP (ORDER BY v.partner_rating) >= 4.5   THEN 'Good (4.5-4.7)'
        WHEN MODE() WITHIN GROUP (ORDER BY v.partner_rating) >= 4.0   THEN 'Average (4.0-4.4)'
        ELSE 'Poor (<4.0)'
    END
FROM staging.v_clean v
JOIN core.dim_restaurant r ON r.restaurant_code = v.restaurant_code
WHERE v.partner_code IS NOT NULL
GROUP BY v.partner_code, r.restaurant_id, r.city_id;

-- 5.4 dim_date -------------------------------------------------------------
INSERT INTO core.dim_date (date_key, day_of_week, day_name, week_of_year,
                           month_num, month_name, is_weekend)
SELECT
    d::DATE,
    EXTRACT(DOW  FROM d)::SMALLINT,
    TRIM(TO_CHAR(d, 'Day')),
    EXTRACT(WEEK FROM d)::SMALLINT,
    EXTRACT(MONTH FROM d)::SMALLINT,
    TRIM(TO_CHAR(d, 'Month')),
    EXTRACT(DOW FROM d) IN (0, 6)
FROM GENERATE_SERIES(
        (SELECT MIN(order_date) FROM staging.v_clean),
        (SELECT MAX(order_date) FROM staging.v_clean),
        INTERVAL '1 day') AS d;


-- ###########################################################################
-- STEP 6 — POPULATE THE FACT TABLE
-- ###########################################################################

INSERT INTO core.fact_orders (
    order_id, restaurant_id, partner_id, city_id, order_date,
    order_ts, pickup_ts, delivered_ts,
    prep_wait_min, time_taken_min, distance_km,
    weather_conditions, road_traffic_density, vehicle_condition,
    type_of_order, type_of_vehicle, multiple_deliveries, is_festival, city_type,
    order_hour, day_part, sla_minutes, sla_breach_min, is_late, speed_kmph,
    has_valid_geo, has_valid_times
)
SELECT
    v.order_id,
    r.restaurant_id,
    p.partner_id,
    r.city_id,
    v.order_date,
    v.order_ts,
    v.pickup_ts,
    v.pickup_ts + MAKE_INTERVAL(mins => v.time_taken_min)          AS delivered_ts,

    EXTRACT(EPOCH FROM (v.pickup_ts - v.order_ts))::INT / 60       AS prep_wait_min,
    v.time_taken_min,

    -- Distance: prefer the row's own geo; fall back to the hub centroid so a
    -- GPS dropout on the pickup point does not cost us the whole row.
    COALESCE(
        v.distance_km,
        core.haversine_km(r.hub_latitude, r.hub_longitude, v.drop_lat, v.drop_lon)
    )                                                              AS distance_km,

    v.weather_conditions,
    v.road_traffic_density,
    v.vehicle_condition,
    v.type_of_order,
    v.type_of_vehicle,
    v.multiple_deliveries,
    COALESCE(v.is_festival, FALSE),
    v.city_type,

    EXTRACT(HOUR FROM v.order_ts)::SMALLINT                        AS order_hour,
    CASE
        WHEN v.order_ts IS NULL                             THEN 'Unknown'
        WHEN EXTRACT(HOUR FROM v.order_ts) <  11             THEN 'Morning'
        WHEN EXTRACT(HOUR FROM v.order_ts) <  15             THEN 'Lunch Peak'
        WHEN EXTRACT(HOUR FROM v.order_ts) <  18             THEN 'Afternoon Lull'
        WHEN EXTRACT(HOUR FROM v.order_ts) <  22             THEN 'Dinner Peak'
        ELSE 'Late Night'
    END                                                            AS day_part,

    sla.sla_minutes,
    (v.time_taken_min - sla.sla_minutes)::SMALLINT                 AS sla_breach_min,
    (v.time_taken_min > sla.sla_minutes)                           AS is_late,

    CASE WHEN v.time_taken_min > 0 AND v.distance_km IS NOT NULL
         THEN ROUND(v.distance_km / (v.time_taken_min / 60.0), 2)
    END                                                            AS speed_kmph,

    v.has_valid_geo,
    v.has_valid_times
FROM staging.v_clean v
JOIN core.dim_restaurant r  ON r.restaurant_code = v.restaurant_code
JOIN core.dim_partner    p  ON p.partner_code    = v.partner_code
JOIN core.sla_policy     sla ON sla.city_type    = v.city_type
WHERE v.time_taken_min IS NOT NULL;


-- ###########################################################################
-- STEP 7 — POST-LOAD VALIDATION
--          If any of these fail, stop and fix before running the analysis.
-- ###########################################################################

\echo '--- referential integrity & row counts ---'
SELECT 'staging rows'      AS metric, COUNT(*)::TEXT AS value FROM staging.stg_deliveries
UNION ALL SELECT 'fact rows loaded',  COUNT(*)::TEXT FROM core.fact_orders
UNION ALL SELECT 'cities',            COUNT(*)::TEXT FROM core.dim_city
UNION ALL SELECT 'restaurants',       COUNT(*)::TEXT FROM core.dim_restaurant
UNION ALL SELECT 'delivery partners', COUNT(*)::TEXT FROM core.dim_partner
UNION ALL SELECT 'date range',
       MIN(order_date)::TEXT || ' to ' || MAX(order_date)::TEXT FROM core.fact_orders
UNION ALL SELECT 'orphan facts (must be 0)',
       COUNT(*)::TEXT FROM core.fact_orders f
       LEFT JOIN core.dim_partner p ON p.partner_id = f.partner_id
       WHERE p.partner_id IS NULL
UNION ALL SELECT 'duplicate order_ids (must be 0)',
       COUNT(*)::TEXT FROM (
           SELECT order_id FROM core.fact_orders GROUP BY order_id HAVING COUNT(*) > 1
       ) dupes
UNION ALL SELECT 'rows with usable geo',
       COUNT(*)::TEXT FROM core.fact_orders WHERE has_valid_geo
UNION ALL SELECT 'rows with usable timestamps',
       COUNT(*)::TEXT FROM core.fact_orders WHERE has_valid_times;

ANALYZE core.fact_orders;

\echo '02_cleaning.sql complete — core schema populated.'
