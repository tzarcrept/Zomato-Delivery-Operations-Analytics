/* ============================================================================
   FILE     : 04_views.sql
   PROJECT  : Zomato Delivery Operations Analytics
   PURPOSE  : The mart layer — the only objects a BI tool should ever touch.
   ENGINE   : PostgreSQL 13+
   RUN      : psql -d zomato_ops -f 04_views.sql
   ----------------------------------------------------------------------------
   WHY THIS LAYER EXISTS
   ---------------------
   Power BI / Tableau / Metabase should never point at core.fact_orders and
   re-derive business logic in DAX or LOD expressions. If "late" is defined in
   three dashboards it will eventually be defined three different ways. These
   views are the contract: one definition of late, one definition of a peak
   hour, one definition of a distance band.

   v_*   = plain views, always current, cheap.
   mv_*  = materialised, for the wide grain that dashboards scan repeatedly.
           Refresh with core.refresh_mart() after any reload.
   ========================================================================== */


/* ---------------------------------------------------------------------------
   1. mart.v_order_detail — the wide, flat, one-row-per-order view.
      This is the single table a BI tool should import. Every dimension is
      already joined and every derived attribute already resolved.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW mart.v_order_detail AS
SELECT
    f.order_id,
    f.order_date,
    d.day_name,
    d.is_weekend,
    d.week_of_year,
    d.month_name,

    c.city_name,
    c.city_tier,
    f.city_type,
    r.restaurant_code                                            AS hub_code,
    p.partner_code,
    p.age_band                                                   AS partner_age_band,
    p.rating_band                                                AS partner_rating_band,
    p.partner_rating,

    f.order_ts,
    f.pickup_ts,
    f.delivered_ts,
    f.order_hour,
    f.day_part,

    f.prep_wait_min,
    f.time_taken_min,
    COALESCE(f.prep_wait_min, 0) + f.time_taken_min              AS total_door_to_door_min,
    f.distance_km,
    f.speed_kmph,

    f.weather_conditions,
    f.road_traffic_density,
    f.vehicle_condition,
    CASE f.vehicle_condition
        WHEN 0 THEN '0 - Poor'
        WHEN 1 THEN '1 - Fair'
        WHEN 2 THEN '2 - Good'
        WHEN 3 THEN '3 - Excellent'
    END                                                          AS vehicle_condition_label,
    f.type_of_order,
    f.type_of_vehicle,
    f.multiple_deliveries,
    CASE WHEN f.multiple_deliveries >= 2 THEN 'Batched 2+'
         WHEN f.multiple_deliveries  = 1 THEN 'Batched 1'
         WHEN f.multiple_deliveries  = 0 THEN 'Not batched'
         ELSE 'Unknown' END                                      AS batching_label,
    f.is_festival,

    CASE
        WHEN f.distance_km IS NULL  THEN 'Unknown'
        WHEN f.distance_km <  5     THEN 'A. under 5 km'
        WHEN f.distance_km < 10     THEN 'B. 5-10 km'
        WHEN f.distance_km < 15     THEN 'C. 10-15 km'
        ELSE                             'D. 15 km+'
    END                                                          AS distance_band,

    f.sla_minutes,
    f.is_late,
    GREATEST(f.sla_breach_min, 0)                                AS minutes_lost,

    f.has_valid_geo,
    f.has_valid_times
FROM core.fact_orders    f
JOIN core.dim_city       c ON c.city_id       = f.city_id
JOIN core.dim_restaurant r ON r.restaurant_id = f.restaurant_id
JOIN core.dim_partner    p ON p.partner_id    = f.partner_id
JOIN core.dim_date       d ON d.date_key      = f.order_date;

COMMENT ON VIEW mart.v_order_detail IS
    'Wide one-row-per-order view. The canonical BI import. 45,584 rows.';


/* ---------------------------------------------------------------------------
   2. mart.v_kpi_daily — the top strip of the dashboard.
      Carries its own 7-day moving average so the BI tool does not have to.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW mart.v_kpi_daily AS
WITH daily AS (
    SELECT
        order_date,
        COUNT(*)                                                 AS orders,
        COUNT(*) FILTER (WHERE is_late)                          AS late_orders,
        ROUND(AVG(time_taken_min), 2)                            AS avg_delivery_min,
        SUM(GREATEST(sla_breach_min, 0))                         AS minutes_lost,
        COUNT(DISTINCT partner_id)                               AS active_partners
    FROM core.fact_orders
    GROUP BY order_date
)
SELECT
    order_date,
    orders,
    late_orders,
    ROUND(100.0 * late_orders / orders, 2)                       AS late_pct,
    avg_delivery_min,
    minutes_lost,
    active_partners,
    ROUND(orders::NUMERIC / NULLIF(active_partners, 0), 2)       AS orders_per_partner,
    ROUND(AVG(100.0 * late_orders / orders) OVER (
        ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2)
                                                                 AS late_pct_7d_ma,
    ROUND(AVG(avg_delivery_min) OVER (
        ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2)
                                                                 AS avg_min_7d_ma
FROM daily;


/* ---------------------------------------------------------------------------
   3. mart.v_city_scorecard — one row per city, ranked. Ops review page.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW mart.v_city_scorecard AS
SELECT
    c.city_name,
    c.city_tier,
    COUNT(*)                                                     AS orders,
    COUNT(DISTINCT f.partner_id)                                 AS partners,
    COUNT(DISTINCT f.restaurant_id)                              AS hubs,
    ROUND(AVG(f.time_taken_min), 1)                              AS avg_delivery_min,
    ROUND(100.0 * AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END), 1) AS late_pct,
    ROUND(AVG(f.distance_km), 2)                                 AS avg_distance_km,
    ROUND(AVG(f.speed_kmph), 1)                                  AS avg_speed_kmph,
    SUM(GREATEST(f.sla_breach_min, 0))                           AS minutes_lost,
    ROUND(100.0 * AVG(CASE WHEN f.road_traffic_density = 'Jam' THEN 1.0 ELSE 0 END), 1)
                                                                 AS pct_orders_in_jam,
    ROUND(100.0 * AVG(CASE WHEN f.vehicle_condition = 0 THEN 1.0 ELSE 0 END), 1)
                                                                 AS pct_poor_vehicles,
    RANK() OVER (ORDER BY AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END))  AS sla_rank,
    RANK() OVER (ORDER BY COUNT(*) DESC)                                 AS volume_rank
FROM core.fact_orders f
JOIN core.dim_city c ON c.city_id = f.city_id
GROUP BY c.city_name, c.city_tier;


/* ---------------------------------------------------------------------------
   4. mart.v_partner_scorecard — one row per partner, benchmarked in-city.
      This is the view a city manager opens on Monday morning.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW mart.v_partner_scorecard AS
WITH base AS (
    SELECT
        p.partner_code,
        c.city_name,
        p.partner_rating,
        p.rating_band,
        p.age_band,
        p.primary_vehicle,
        COUNT(*)                                                 AS orders,
        ROUND(AVG(f.time_taken_min), 2)                          AS avg_delivery_min,
        ROUND(STDDEV_SAMP(f.time_taken_min), 2)                  AS sd_delivery_min,
        ROUND(100.0 * AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END), 1) AS late_pct,
        SUM(GREATEST(f.sla_breach_min, 0))                       AS minutes_lost,
        ROUND(AVG(f.distance_km), 2)                             AS avg_distance_km
    FROM core.fact_orders f
    JOIN core.dim_partner p ON p.partner_id = f.partner_id
    JOIN core.dim_city    c ON c.city_id    = f.city_id
    GROUP BY p.partner_code, c.city_name, p.partner_rating,
             p.rating_band, p.age_band, p.primary_vehicle
)
SELECT
    b.*,
    ROUND(b.sd_delivery_min / NULLIF(b.avg_delivery_min, 0), 3)  AS coeff_of_variation,
    RANK()    OVER (PARTITION BY b.city_name ORDER BY b.late_pct) AS rank_in_city,
    NTILE(4)  OVER (ORDER BY b.late_pct)                          AS national_quartile,
    ROUND(b.late_pct - AVG(b.late_pct) OVER (PARTITION BY b.city_name), 1)
                                                                  AS pts_vs_city_avg,
    CASE
        WHEN NTILE(4) OVER (ORDER BY b.late_pct) = 1 THEN 'Top performer'
        WHEN NTILE(4) OVER (ORDER BY b.late_pct) = 4 THEN 'Needs coaching'
        ELSE 'Core'
    END                                                           AS coaching_flag
FROM base b
WHERE b.orders >= 10;


/* ---------------------------------------------------------------------------
   5. mart.v_hub_scorecard — one row per restaurant / dispatch hub.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW mart.v_hub_scorecard AS
SELECT
    r.restaurant_code                                            AS hub_code,
    c.city_name,
    r.hub_latitude,
    r.hub_longitude,
    COUNT(*)                                                     AS orders,
    COUNT(DISTINCT f.partner_id)                                 AS partners_attached,
    ROUND(AVG(f.time_taken_min), 1)                              AS avg_delivery_min,
    ROUND(AVG(f.prep_wait_min), 1)                               AS avg_prep_wait_min,
    ROUND(100.0 * AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END), 1) AS late_pct,
    SUM(GREATEST(f.sla_breach_min, 0))                           AS minutes_lost,
    ROUND(100.0 * (AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END)
          - AVG(AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END))
            OVER (PARTITION BY c.city_name)), 1)                 AS pts_vs_city_avg,
    RANK() OVER (ORDER BY SUM(GREATEST(f.sla_breach_min, 0)) DESC) AS lost_minutes_rank
FROM core.fact_orders f
JOIN core.dim_restaurant r ON r.restaurant_id = f.restaurant_id
JOIN core.dim_city       c ON c.city_id       = f.city_id
GROUP BY r.restaurant_code, c.city_name, r.hub_latitude, r.hub_longitude;


/* ---------------------------------------------------------------------------
   6. mart.mv_ops_heatmap — MATERIALISED. Hour x day-of-week x city-tier.
      This is the grain a heatmap visual scans on every filter change, so it is
      worth paying for it once at refresh time rather than on every render.
   --------------------------------------------------------------------------- */
DROP MATERIALIZED VIEW IF EXISTS mart.mv_ops_heatmap;
CREATE MATERIALIZED VIEW mart.mv_ops_heatmap AS
SELECT
    c.city_tier,
    d.day_name,
    d.day_of_week,
    f.order_hour,
    f.day_part,
    COUNT(*)                                                     AS orders,
    ROUND(AVG(f.time_taken_min), 1)                              AS avg_delivery_min,
    ROUND(100.0 * AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END), 1) AS late_pct,
    SUM(GREATEST(f.sla_breach_min, 0))                           AS minutes_lost,
    COUNT(DISTINCT f.partner_id)                                 AS active_partners,
    ROUND(COUNT(*)::NUMERIC / NULLIF(COUNT(DISTINCT f.partner_id), 0), 2)
                                                                 AS orders_per_partner
FROM core.fact_orders f
JOIN core.dim_city c ON c.city_id  = f.city_id
JOIN core.dim_date d ON d.date_key = f.order_date
WHERE f.order_hour IS NOT NULL
GROUP BY c.city_tier, d.day_name, d.day_of_week, f.order_hour, f.day_part;

CREATE UNIQUE INDEX idx_mv_heatmap
    ON mart.mv_ops_heatmap (city_tier, day_of_week, order_hour);


/* ---------------------------------------------------------------------------
   7. mart.mv_condition_matrix — MATERIALISED. Traffic x weather x distance.
      Backs the root-cause page.
   --------------------------------------------------------------------------- */
DROP MATERIALIZED VIEW IF EXISTS mart.mv_condition_matrix;
CREATE MATERIALIZED VIEW mart.mv_condition_matrix AS
WITH base AS (
    SELECT
        COALESCE(road_traffic_density, 'Unknown')                AS traffic,
        COALESCE(weather_conditions,   'Unknown')                AS weather,
        CASE
            WHEN distance_km IS NULL THEN 'Unknown'
            WHEN distance_km <  5    THEN 'A. under 5 km'
            WHEN distance_km < 10    THEN 'B. 5-10 km'
            WHEN distance_km < 15    THEN 'C. 10-15 km'
            ELSE                          'D. 15 km+'
        END                                                      AS distance_band,
        time_taken_min,
        is_late,
        GREATEST(sla_breach_min, 0)                              AS minutes_lost
    FROM core.fact_orders
)
SELECT
    traffic,
    weather,
    distance_band,
    COUNT(*)                                                     AS orders,
    ROUND(AVG(time_taken_min), 1)                                AS avg_delivery_min,
    ROUND(100.0 * AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END), 1) AS late_pct,
    SUM(minutes_lost)                                            AS minutes_lost,
    ROUND(100.0 * SUM(minutes_lost) / SUM(SUM(minutes_lost)) OVER (), 2)
                                                                 AS pct_of_all_lost,
    ROUND(AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END)
          / NULLIF((SELECT AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END)
                    FROM core.fact_orders), 0), 2)               AS late_rate_lift
FROM base
GROUP BY traffic, weather, distance_band;

CREATE UNIQUE INDEX idx_mv_condition
    ON mart.mv_condition_matrix (traffic, weather, distance_band);


/* ---------------------------------------------------------------------------
   8. Refresh helper — call after every reload of core.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.refresh_mart()
RETURNS TEXT
LANGUAGE plpgsql AS
$$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.mv_ops_heatmap;
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.mv_condition_matrix;
    RETURN 'mart refreshed at ' || NOW()::TEXT;
END;
$$;


/* ---------------------------------------------------------------------------
   9. Smoke test — every mart object returns rows.
   --------------------------------------------------------------------------- */
\echo '--- mart layer row counts ---'
SELECT 'v_order_detail'      AS object, COUNT(*) AS rows FROM mart.v_order_detail
UNION ALL SELECT 'v_kpi_daily',          COUNT(*) FROM mart.v_kpi_daily
UNION ALL SELECT 'v_city_scorecard',     COUNT(*) FROM mart.v_city_scorecard
UNION ALL SELECT 'v_partner_scorecard',  COUNT(*) FROM mart.v_partner_scorecard
UNION ALL SELECT 'v_hub_scorecard',      COUNT(*) FROM mart.v_hub_scorecard
UNION ALL SELECT 'mv_ops_heatmap',       COUNT(*) FROM mart.mv_ops_heatmap
UNION ALL SELECT 'mv_condition_matrix',  COUNT(*) FROM mart.mv_condition_matrix
ORDER BY object;

\echo '04_views.sql complete — mart layer ready for BI connection.'
