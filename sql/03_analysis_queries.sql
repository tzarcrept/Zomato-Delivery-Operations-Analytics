/* ============================================================================
   FILE     : 03_analysis_queries.sql
   PROJECT  : Zomato Delivery Operations Analytics
   PURPOSE  : Twenty business questions, answered against core.fact_orders.
   ENGINE   : PostgreSQL 13+
   RUN      : psql -d zomato_ops -f 03_analysis_queries.sql
              (or open in a client and run one block at a time)
   ----------------------------------------------------------------------------
   BRIEF FROM OPS
   --------------
   "Roughly three in ten of our orders miss the promised window. Tell us what
    is actually causing it, where it is concentrated, and what we should change
    first."

   Each block states the business question, the technique used, and — in the
   INSIGHT comment — what the result actually showed when this was run.
   ========================================================================== */

\timing on
\pset pager off


/* ###########################################################################
   SECTION A — EXECUTIVE VIEW
   ########################################################################### */

/* ---------------------------------------------------------------------------
   Q1. What does the operation look like at a glance?
   Technique: conditional aggregation, FILTER clause
   --------------------------------------------------------------------------- */
SELECT
    COUNT(*)                                                    AS total_orders,
    COUNT(DISTINCT partner_id)                                  AS active_partners,
    COUNT(DISTINCT restaurant_id)                               AS active_hubs,
    COUNT(DISTINCT city_id)                                     AS cities,
    ROUND(AVG(time_taken_min), 1)                               AS avg_delivery_min,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY time_taken_min) AS median_min,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY time_taken_min) AS p95_min,
    COUNT(*) FILTER (WHERE is_late)                             AS late_orders,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 2) AS late_pct,
    SUM(sla_breach_min) FILTER (WHERE is_late)                  AS total_minutes_late,
    ROUND(AVG(sla_breach_min) FILTER (WHERE is_late), 1)        AS avg_overrun_when_late
FROM core.fact_orders;
-- INSIGHT: 45,584 orders, 1,320 partners, 22 cities. 29.8% breach the SLA.
--          Median delivery is 26 min but p95 is 42 min — the tail, not the
--          average, is what customers complain about.


/* ---------------------------------------------------------------------------
   Q2. Is performance improving or degrading over the period?
   Technique: window functions — 7-day moving average, LAG for week-on-week
   --------------------------------------------------------------------------- */
WITH daily AS (
    SELECT
        order_date,
        COUNT(*)                                                 AS orders,
        ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 2) AS late_pct,
        ROUND(AVG(time_taken_min), 2)                            AS avg_min
    FROM core.fact_orders
    GROUP BY order_date
)
SELECT
    order_date,
    orders,
    late_pct,
    avg_min,
    ROUND(AVG(late_pct) OVER (
        ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2)
                                                                 AS late_pct_7d_ma,
    ROUND(late_pct - LAG(late_pct, 7) OVER (ORDER BY order_date), 2)
                                                                 AS wow_change_pts,
    SUM(orders) OVER (ORDER BY order_date)                       AS cumulative_orders
FROM daily
ORDER BY order_date;
-- INSIGHT: the late rate is stable, not trending. This is a structural
--          problem, not a recent regression — so the fix is process, not a
--          rollback of something that changed.


/* ###########################################################################
   SECTION B — ROOT CAUSE: WHAT ACTUALLY DRIVES LATENESS
   ########################################################################### */

/* ---------------------------------------------------------------------------
   Q3. Which combination of road and weather conditions is most damaging?
   Technique: cross-tab aggregation with lift vs. the overall baseline
   --------------------------------------------------------------------------- */
WITH baseline AS (
    SELECT AVG(time_taken_min) AS base_min,
           AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END) AS base_late
    FROM core.fact_orders
)
SELECT
    f.road_traffic_density,
    f.weather_conditions,
    COUNT(*)                                                     AS orders,
    ROUND(AVG(f.time_taken_min), 1)                              AS avg_min,
    ROUND(100.0 * AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END), 1) AS late_pct,
    ROUND(AVG(f.time_taken_min) - b.base_min, 1)                 AS min_vs_baseline,
    ROUND(AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END) / NULLIF(b.base_late,0), 2)
                                                                 AS late_rate_lift
FROM core.fact_orders f
CROSS JOIN baseline b
WHERE f.road_traffic_density IS NOT NULL
  AND f.weather_conditions   IS NOT NULL
GROUP BY f.road_traffic_density, f.weather_conditions, b.base_min, b.base_late
HAVING COUNT(*) >= 100
ORDER BY late_pct DESC
LIMIT 15;
-- INSIGHT: traffic dominates weather. "Jam" conditions run a ~50% late rate
--          against a 30% baseline — a 1.7x lift — while "Low" traffic sits at
--          8%. Weather modulates this but never reverses it.


/* ---------------------------------------------------------------------------
   Q4. Pareto — how few condition-combinations account for most lost minutes?
   Technique: CTE + cumulative window SUM to build a running contribution curve
   --------------------------------------------------------------------------- */
WITH breach AS (
    SELECT
        COALESCE(road_traffic_density,'Unknown') || ' / ' ||
        COALESCE(weather_conditions,'Unknown')   AS condition_combo,
        SUM(GREATEST(sla_breach_min, 0))         AS lost_minutes,
        COUNT(*)                                 AS orders
    FROM core.fact_orders
    GROUP BY 1
),
ranked AS (
    SELECT
        condition_combo,
        orders,
        lost_minutes,
        ROUND(100.0 * lost_minutes / SUM(lost_minutes) OVER (), 2) AS pct_of_lost,
        ROUND(100.0 * SUM(lost_minutes) OVER (ORDER BY lost_minutes DESC
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
              / SUM(lost_minutes) OVER (), 2)                      AS cumulative_pct,
        ROW_NUMBER() OVER (ORDER BY lost_minutes DESC)             AS rn
    FROM breach
)
SELECT * FROM ranked WHERE cumulative_pct <= 85 OR rn <= 8 ORDER BY rn;
-- INSIGHT: a handful of "Jam" combinations carry the large majority of all
--          lost minutes. Targeting traffic-jam windows in a few cities beats
--          any company-wide initiative on cost-per-minute-recovered.


/* ---------------------------------------------------------------------------
   Q5. Does distance explain lateness, or is it a red herring?
   Technique: NTILE to build distance deciles, then compare within decile
   --------------------------------------------------------------------------- */
WITH deciles AS (
    SELECT
        NTILE(10) OVER (ORDER BY distance_km) AS distance_decile,
        distance_km,
        time_taken_min,
        is_late,
        speed_kmph
    FROM core.fact_orders
    WHERE distance_km IS NOT NULL
)
SELECT
    distance_decile,
    COUNT(*)                                                     AS orders,
    ROUND(MIN(distance_km), 2)                                   AS min_km,
    ROUND(MAX(distance_km), 2)                                   AS max_km,
    ROUND(AVG(time_taken_min), 1)                                AS avg_min,
    ROUND(100.0 * AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END), 1) AS late_pct,
    ROUND(AVG(speed_kmph), 1)                                    AS avg_kmph
FROM deciles
GROUP BY distance_decile
ORDER BY distance_decile;
-- INSIGHT: distance is a step function, not a slope. Deciles 1-5 (under 9 km)
--          breach at 10-23%. Decile 6 onwards jumps to 35-46% and then FLATTENS.
--          The break sits at roughly 10 km: beyond it the promised 30-minute
--          window is barely achievable regardless of how far past 10 km the
--          drop actually is. This argues for a distance-tiered SLA, not for
--          trying to make long drops faster.


/* ---------------------------------------------------------------------------
   Q6. Holding distance constant, how much does traffic still cost us?
   Technique: two-way segmentation to control for a confounder
   --------------------------------------------------------------------------- */
SELECT
    CASE
        WHEN distance_km <  5  THEN 'A. under 5 km'
        WHEN distance_km < 10  THEN 'B. 5-10 km'
        WHEN distance_km < 15  THEN 'C. 10-15 km'
        ELSE                        'D. 15 km+'
    END                                                          AS distance_band,
    road_traffic_density,
    COUNT(*)                                                     AS orders,
    ROUND(AVG(time_taken_min), 1)                                AS avg_min,
    ROUND(100.0 * AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END), 1) AS late_pct
FROM core.fact_orders
WHERE distance_km IS NOT NULL AND road_traffic_density IS NOT NULL
GROUP BY distance_band, road_traffic_density
ORDER BY distance_band, avg_min DESC;
-- INSIGHT: distance and traffic COMPOUND rather than substitute. The best cell
--          (under 5 km, Low traffic) breaches 2.2% of the time; the worst
--          (10-15 km, Jam) breaches 61.6% — a 28x spread. Neither variable is a
--          confounder for the other, and the worst cells are where the promise,
--          not the execution, is the thing that is broken.


/* ---------------------------------------------------------------------------
   Q7. What does batching (multiple deliveries per trip) cost the customer?
   Technique: segmentation with a per-order marginal cost calculation
   --------------------------------------------------------------------------- */
SELECT
    multiple_deliveries                                          AS orders_batched,
    COUNT(*)                                                     AS orders,
    ROUND(AVG(time_taken_min), 1)                                AS avg_min,
    ROUND(AVG(time_taken_min) - FIRST_VALUE(AVG(time_taken_min))
          OVER (ORDER BY multiple_deliveries), 1)                AS min_vs_no_batch,
    ROUND(100.0 * AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END), 1) AS late_pct,
    ROUND(AVG(distance_km), 2)                                   AS avg_km
FROM core.fact_orders
WHERE multiple_deliveries IS NOT NULL
GROUP BY multiple_deliveries
ORDER BY multiple_deliveries;
-- INSIGHT: batching is close to a switch. Unbatched trips breach 18.1% of the
--          time and single-batch 30.2%, but at TWO batched orders the breach
--          rate hits 99.9% and at three it is 100.0%. Batching two or more
--          orders is not a trade-off, it is a guaranteed SLA failure under the
--          current 30-minute promise.


/* ---------------------------------------------------------------------------
   Q8. Do festival days need a different service promise?
   Technique: conditional aggregation with a paired comparison
   --------------------------------------------------------------------------- */
SELECT
    CASE WHEN is_festival THEN 'Festival' ELSE 'Normal day' END  AS day_type,
    COUNT(*)                                                     AS orders,
    ROUND(AVG(time_taken_min), 1)                                AS avg_min,
    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY time_taken_min) AS p90_min,
    ROUND(100.0 * AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END), 1) AS late_pct,
    ROUND(AVG(GREATEST(sla_breach_min,0)), 1)                    AS avg_lost_min
FROM core.fact_orders
GROUP BY day_type;
-- INSIGHT: festival days average 45.5 min against 25.9 on normal days and
--          breach 99.8% of the time. Only 896 orders, so the volume impact is
--          small — but promising 30 minutes on a festival date is a promise the
--          operation cannot keep, and should not be making.


/* ###########################################################################
   SECTION C — TIME AND DEMAND
   ########################################################################### */

/* ---------------------------------------------------------------------------
   Q9. Which hours of the day are under the most stress?
   Technique: window function to compute each hour's share of daily volume
   --------------------------------------------------------------------------- */
WITH hourly AS (
    SELECT
        order_hour,
        COUNT(*)                                                 AS orders,
        ROUND(AVG(time_taken_min), 1)                            AS avg_min,
        ROUND(100.0 * AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END), 1) AS late_pct,
        COUNT(DISTINCT partner_id)                               AS partners_active,
        SUM(GREATEST(sla_breach_min, 0))                         AS lost_minutes
    FROM core.fact_orders
    WHERE order_hour IS NOT NULL
    GROUP BY order_hour
)
SELECT
    order_hour,
    orders,
    ROUND(100.0 * orders / SUM(orders) OVER (), 2)               AS pct_of_volume,
    avg_min,
    late_pct,
    partners_active,
    ROUND(orders::NUMERIC / NULLIF(partners_active, 0), 2)       AS orders_per_partner,
    lost_minutes,
    RANK() OVER (ORDER BY lost_minutes DESC)                     AS stress_rank
FROM hourly
ORDER BY order_hour;
-- INSIGHT: the 19:00-21:00 window carries the worst breach rates (49-51%) and
--          the most lost minutes. But note hours 22-23: near-identical
--          orders-per-partner (~3.97) yet only 12-15% breach. Rider supply is
--          therefore NOT the binding constraint — the 19-21 damage is traffic
--          and demand-mix, not headcount. Morning hours 08:00-10:00 breach
--          under 3%, confirming the operation is capable when roads are clear.


/* ---------------------------------------------------------------------------
   Q10. How does the day-part pattern differ by city tier?
   Technique: multi-dimensional grouping with a within-group percentage
   --------------------------------------------------------------------------- */
SELECT
    c.city_tier,
    f.day_part,
    COUNT(*)                                                     AS orders,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY c.city_tier), 1)
                                                                 AS pct_of_tier_volume,
    ROUND(AVG(f.time_taken_min), 1)                              AS avg_min,
    ROUND(100.0 * AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END), 1) AS late_pct
FROM core.fact_orders f
JOIN core.dim_city c ON c.city_id = f.city_id
WHERE f.day_part <> 'Unknown'
GROUP BY c.city_tier, f.day_part
ORDER BY c.city_tier, orders DESC;


/* ---------------------------------------------------------------------------
   Q11. Weekday vs weekend — do we need different staffing on each?
   Technique: dimension join, paired aggregation
   --------------------------------------------------------------------------- */
SELECT
    d.day_name,
    d.is_weekend,
    COUNT(*)                                                     AS orders,
    ROUND(AVG(f.time_taken_min), 1)                              AS avg_min,
    ROUND(100.0 * AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END), 1) AS late_pct,
    COUNT(DISTINCT f.partner_id)                                 AS partners_used,
    ROUND(COUNT(*)::NUMERIC / COUNT(DISTINCT f.partner_id), 1)   AS orders_per_partner
FROM core.fact_orders f
JOIN core.dim_date d ON d.date_key = f.order_date
GROUP BY d.day_name, d.is_weekend, d.day_of_week
ORDER BY d.day_of_week;


/* ---------------------------------------------------------------------------
   Q12. Where is demand outrunning rider supply?
   Technique: derived utilisation metric, ranked, with a national comparison
   --------------------------------------------------------------------------- */
WITH city_load AS (
    SELECT
        c.city_name,
        c.city_tier,
        COUNT(*)                                                 AS orders,
        COUNT(DISTINCT f.partner_id)                             AS partners,
        COUNT(DISTINCT f.order_date)                             AS active_days,
        ROUND(100.0 * AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END), 1) AS late_pct
    FROM core.fact_orders f
    JOIN core.dim_city c ON c.city_id = f.city_id
    GROUP BY c.city_name, c.city_tier
)
SELECT
    city_name,
    city_tier,
    orders,
    partners,
    ROUND(orders::NUMERIC / partners / NULLIF(active_days,0), 2) AS orders_per_partner_per_day,
    late_pct,
    ROUND(late_pct - AVG(late_pct) OVER (), 1)                   AS pts_vs_national,
    RANK() OVER (ORDER BY orders::NUMERIC / partners / NULLIF(active_days,0) DESC)
                                                                 AS load_rank
FROM city_load
ORDER BY load_rank;
-- INSIGHT: a genuine negative result, and an important one. Every city runs
--          ~60 partners at 1.4-1.6 orders/partner/day, and every city's breach
--          rate lands in a narrow 29-33% band. There is no problem city and no
--          model city. Uniformity at this level means the cause is systemic —
--          the SLA policy and the dispatch rules — not local execution, so a
--          city-by-city intervention would be the wrong programme to fund.


/* ###########################################################################
   SECTION D — DELIVERY PARTNER PERFORMANCE
   ########################################################################### */

/* ---------------------------------------------------------------------------
   Q13. Who are the best and worst partners, fairly compared?
   Technique: RANK and PERCENT_RANK partitioned by city, so a Mumbai rider is
              benchmarked against Mumbai, not against Mysuru
   --------------------------------------------------------------------------- */
WITH partner_stats AS (
    SELECT
        p.partner_code,
        c.city_name,
        p.partner_rating,
        p.primary_vehicle,
        COUNT(*)                                                 AS orders,
        ROUND(AVG(f.time_taken_min), 2)                          AS avg_min,
        ROUND(100.0 * AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END), 1) AS late_pct,
        ROUND(STDDEV_SAMP(f.time_taken_min), 2)                  AS consistency_sd
    FROM core.fact_orders f
    JOIN core.dim_partner p ON p.partner_id = f.partner_id
    JOIN core.dim_city    c ON c.city_id    = f.city_id
    GROUP BY p.partner_code, c.city_name, p.partner_rating, p.primary_vehicle
    HAVING COUNT(*) >= 20
)
SELECT
    partner_code,
    city_name,
    orders,
    avg_min,
    late_pct,
    consistency_sd,
    partner_rating,
    RANK()         OVER (PARTITION BY city_name ORDER BY late_pct)        AS rank_in_city,
    ROUND(PERCENT_RANK() OVER (ORDER BY late_pct)::NUMERIC, 3)            AS national_pctile,
    NTILE(4)       OVER (ORDER BY late_pct)                               AS performance_quartile
FROM partner_stats
ORDER BY late_pct
LIMIT 25;


/* ---------------------------------------------------------------------------
   Q14. Is the partner star-rating actually predictive of delivery performance?
   Technique: banding an input variable and testing it against the outcome
   --------------------------------------------------------------------------- */
SELECT
    p.rating_band,
    COUNT(DISTINCT p.partner_id)                                 AS partners,
    COUNT(*)                                                     AS orders,
    ROUND(AVG(f.time_taken_min), 1)                              AS avg_min,
    ROUND(100.0 * AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END), 1) AS late_pct,
    ROUND(AVG(f.speed_kmph), 1)                                  AS avg_kmph
FROM core.fact_orders f
JOIN core.dim_partner p ON p.partner_id = f.partner_id
GROUP BY p.rating_band
ORDER BY late_pct;
-- INSIGHT: the star rating does NOT discriminate where it matters. "Excellent"
--          (4.8+) and "Good" (4.5-4.7) partners breach at an identical 29.7%.
--          Only the small "Average" band (4.0-4.4, 483 orders) is meaningfully
--          worse at 41.0%. Because 99% of partners sit at 4.5+, the rating is
--          compressed to the point of being useless as a dispatch signal —
--          it separates the bottom 1% and nothing else.


/* ---------------------------------------------------------------------------
   Q15. Are partners improving with tenure on the platform?
   Technique: split the period in half per partner, then LAG across the halves
   --------------------------------------------------------------------------- */
WITH halves AS (
    SELECT
        f.partner_id,
        CASE WHEN f.order_date <= (SELECT MIN(order_date) + (MAX(order_date) - MIN(order_date))/2
                                   FROM core.fact_orders)
             THEN 'H1' ELSE 'H2' END                             AS period_half,
        AVG(f.time_taken_min)                                    AS avg_min,
        COUNT(*)                                                 AS orders
    FROM core.fact_orders f
    GROUP BY f.partner_id, period_half
),
paired AS (
    SELECT
        partner_id,
        MAX(avg_min) FILTER (WHERE period_half = 'H1')           AS h1_avg,
        MAX(avg_min) FILTER (WHERE period_half = 'H2')           AS h2_avg,
        SUM(orders)                                              AS total_orders
    FROM halves
    GROUP BY partner_id
    HAVING COUNT(DISTINCT period_half) = 2
)
SELECT
    CASE
        WHEN h2_avg - h1_avg < -2 THEN 'Improved  (>2 min faster)'
        WHEN h2_avg - h1_avg >  2 THEN 'Regressed (>2 min slower)'
        ELSE                           'Stable'
    END                                                          AS trajectory,
    COUNT(*)                                                     AS partners,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)           AS pct_of_partners,
    ROUND(AVG(h1_avg), 1)                                        AS avg_min_h1,
    ROUND(AVG(h2_avg), 1)                                        AS avg_min_h2
FROM paired
GROUP BY trajectory
ORDER BY partners DESC;


/* ---------------------------------------------------------------------------
   Q16. Does the vehicle — type or condition — matter?
   Technique: two-factor segmentation with volume guardrail
   --------------------------------------------------------------------------- */
SELECT
    type_of_vehicle,
    vehicle_condition,
    COUNT(*)                                                     AS orders,
    ROUND(AVG(time_taken_min), 1)                                AS avg_min,
    ROUND(100.0 * AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END), 1) AS late_pct,
    ROUND(AVG(speed_kmph), 1)                                    AS avg_kmph
FROM core.fact_orders
WHERE type_of_vehicle IS NOT NULL
GROUP BY type_of_vehicle, vehicle_condition
HAVING COUNT(*) >= 200
ORDER BY type_of_vehicle, vehicle_condition;
-- INSIGHT: vehicle condition is a cliff, not a gradient. Condition 0 averages
--          30.1 min and breaches 41.7%; conditions 1 and 2 are effectively
--          identical (24.4/24.5 min, ~24%). Condition 0 covers 15,005 orders —
--          a third of the book — so this is the largest single controllable
--          lever in the dataset. Maintenance, not hiring.


/* ---------------------------------------------------------------------------
   Q17. Which partners are erratic rather than simply slow?
        (A consistently 28-minute rider is easier to plan around than one who
         swings between 15 and 45.)
   Technique: coefficient of variation, plus a two-axis classification
   --------------------------------------------------------------------------- */
WITH stats AS (
    SELECT
        p.partner_code,
        c.city_name,
        COUNT(*)                                                 AS orders,
        AVG(f.time_taken_min)                                    AS avg_min,
        STDDEV_SAMP(f.time_taken_min)                            AS sd_min
    FROM core.fact_orders f
    JOIN core.dim_partner p ON p.partner_id = f.partner_id
    JOIN core.dim_city    c ON c.city_id    = f.city_id
    GROUP BY p.partner_code, c.city_name
    HAVING COUNT(*) >= 25
)
SELECT
    partner_code,
    city_name,
    orders,
    ROUND(avg_min, 1)                                            AS avg_min,
    ROUND(sd_min, 2)                                             AS sd_min,
    ROUND(sd_min / NULLIF(avg_min, 0), 3)                        AS coeff_of_variation,
    CASE
        WHEN avg_min <= (SELECT AVG(avg_min) FROM stats)
         AND sd_min  <= (SELECT AVG(sd_min)  FROM stats) THEN 'Fast & consistent'
        WHEN avg_min <= (SELECT AVG(avg_min) FROM stats) THEN 'Fast but erratic'
        WHEN sd_min  <= (SELECT AVG(sd_min)  FROM stats) THEN 'Slow but predictable'
        ELSE                                                  'Slow & erratic'
    END                                                          AS segment
FROM stats
ORDER BY coeff_of_variation DESC
LIMIT 25;


/* ###########################################################################
   SECTION E — LOCATION AND SIZING THE FIX
   ########################################################################### */

/* ---------------------------------------------------------------------------
   Q18. Which restaurant hubs are chronic underperformers?
   Technique: benchmark each hub against its own city's average, not the national
   --------------------------------------------------------------------------- */
WITH hub_perf AS (
    SELECT
        r.restaurant_code,
        c.city_name,
        COUNT(*)                                                 AS orders,
        AVG(f.time_taken_min)                                    AS avg_min,
        AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END)             AS late_rate,
        SUM(GREATEST(f.sla_breach_min, 0))                       AS lost_minutes
    FROM core.fact_orders f
    JOIN core.dim_restaurant r ON r.restaurant_id = f.restaurant_id
    JOIN core.dim_city       c ON c.city_id       = f.city_id
    GROUP BY r.restaurant_code, c.city_name
    HAVING COUNT(*) >= 50
)
SELECT
    restaurant_code,
    city_name,
    orders,
    ROUND(avg_min, 1)                                            AS avg_min,
    ROUND(100.0 * late_rate, 1)                                  AS late_pct,
    ROUND(100.0 * (late_rate - AVG(late_rate) OVER (PARTITION BY city_name)), 1)
                                                                 AS pts_vs_city_avg,
    lost_minutes,
    ROUND(100.0 * lost_minutes / SUM(lost_minutes) OVER (), 2)   AS pct_of_all_lost_min,
    RANK() OVER (ORDER BY late_rate DESC)                        AS worst_rank
FROM hub_perf
ORDER BY worst_rank
LIMIT 20;


/* ---------------------------------------------------------------------------
   Q19. City scorecard for the ops review.
   Technique: multiple ranked measures side by side in one pass
   --------------------------------------------------------------------------- */
SELECT
    c.city_name,
    c.city_tier,
    COUNT(*)                                                     AS orders,
    ROUND(AVG(f.time_taken_min), 1)                              AS avg_min,
    ROUND(100.0 * AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END), 1) AS late_pct,
    ROUND(AVG(f.distance_km), 2)                                 AS avg_km,
    ROUND(AVG(f.speed_kmph), 1)                                  AS avg_kmph,
    ROUND(100.0 * AVG(CASE WHEN f.road_traffic_density = 'Jam' THEN 1.0 ELSE 0 END), 1)
                                                                 AS pct_orders_in_jam,
    RANK() OVER (ORDER BY AVG(CASE WHEN f.is_late THEN 1.0 ELSE 0 END))      AS sla_rank,
    RANK() OVER (ORDER BY COUNT(*) DESC)                                     AS volume_rank
FROM core.fact_orders f
JOIN core.dim_city c ON c.city_id = f.city_id
GROUP BY c.city_name, c.city_tier
ORDER BY late_pct DESC;


/* ---------------------------------------------------------------------------
   Q20. SIZING THE RECOMMENDATION — which intervention actually pays?
        Four candidate programmes are modelled against the same baseline and
        expressed in one common currency: share of total SLA breaches removed.
   Technique: counterfactual modelling in pure SQL. Each CTE re-scores every
              affected order under the intervention, then re-tests it against
              the SLA. This is the query that turns analysis into a business
              case — it tells ops what to fund first.
   --------------------------------------------------------------------------- */
WITH baseline AS (
    SELECT COUNT(*) FILTER (WHERE is_late) AS total_breaches
    FROM core.fact_orders
),

-- Programme 1: fleet maintenance — bring condition-0 vehicles up to condition 1
fleet AS (
    SELECT
        'P1  Fleet maintenance (condition 0 -> 1)'                AS programme,
        COUNT(*)                                                  AS orders_in_scope,
        COUNT(*) FILTER (WHERE f.is_late)                         AS breaches_in_scope,
        COUNT(*) FILTER (
            WHERE f.is_late
              AND f.time_taken_min - g.gap <= f.sla_minutes
        )                                                         AS breaches_recovered
    FROM core.fact_orders f
    CROSS JOIN (
        SELECT AVG(time_taken_min) FILTER (WHERE vehicle_condition = 0)
             - AVG(time_taken_min) FILTER (WHERE vehicle_condition = 1) AS gap
        FROM core.fact_orders
    ) g
    WHERE f.vehicle_condition = 0
),

-- Programme 2: dispatch rule — never batch more than one order per trip
batching AS (
    SELECT
        'P2  Cap batching at 1 order per trip'                    AS programme,
        COUNT(*)                                                  AS orders_in_scope,
        COUNT(*) FILTER (WHERE f.is_late)                         AS breaches_in_scope,
        COUNT(*) FILTER (
            WHERE f.is_late
              AND f.time_taken_min - prem.premium <= f.sla_minutes
        )                                                         AS breaches_recovered
    FROM core.fact_orders f
    JOIN (
        SELECT
            multiple_deliveries AS md,
            AVG(time_taken_min) - (SELECT AVG(time_taken_min)
                                   FROM core.fact_orders
                                   WHERE multiple_deliveries = 1) AS premium
        FROM core.fact_orders
        WHERE multiple_deliveries >= 2
        GROUP BY multiple_deliveries
    ) prem ON prem.md = f.multiple_deliveries
),

-- Programme 3: coaching — lift below-median partners to their own city median
coaching AS (
    WITH partner_perf AS (
        SELECT partner_id, city_id, AVG(time_taken_min) AS partner_avg
        FROM core.fact_orders
        GROUP BY partner_id, city_id
        HAVING COUNT(*) >= 10
    ),
    city_median AS (
        SELECT city_id,
               PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY partner_avg) AS med
        FROM partner_perf GROUP BY city_id
    ),
    below AS (
        SELECT pp.partner_id, pp.partner_avg - cm.med AS excess
        FROM partner_perf pp
        JOIN city_median cm ON cm.city_id = pp.city_id
        WHERE pp.partner_avg > cm.med
    )
    SELECT
        'P3  Coach below-median partners to city median'          AS programme,
        COUNT(*)                                                  AS orders_in_scope,
        COUNT(*) FILTER (WHERE f.is_late)                         AS breaches_in_scope,
        COUNT(*) FILTER (
            WHERE f.is_late
              AND f.time_taken_min - b.excess <= f.sla_minutes
        )                                                         AS breaches_recovered
    FROM core.fact_orders f
    JOIN below b ON b.partner_id = f.partner_id
),

-- Programme 4: policy — widen the promise to 45 minutes on festival dates
festival_sla AS (
    SELECT
        'P4  45-min SLA on festival dates'                        AS programme,
        COUNT(*)                                                  AS orders_in_scope,
        COUNT(*) FILTER (WHERE is_late)                           AS breaches_in_scope,
        COUNT(*) FILTER (WHERE is_late AND time_taken_min <= 45)  AS breaches_recovered
    FROM core.fact_orders
    WHERE is_festival
),

all_programmes AS (
    SELECT * FROM fleet
    UNION ALL SELECT * FROM batching
    UNION ALL SELECT * FROM coaching
    UNION ALL SELECT * FROM festival_sla
)
SELECT
    a.programme,
    a.orders_in_scope,
    a.breaches_in_scope,
    a.breaches_recovered,
    ROUND(100.0 * a.breaches_recovered / NULLIF(a.breaches_in_scope, 0), 1)
                                                         AS pct_of_scope_fixed,
    ROUND(100.0 * a.breaches_recovered / b.total_breaches, 1)
                                                         AS pct_of_ALL_breaches_fixed,
    RANK() OVER (ORDER BY a.breaches_recovered DESC)      AS funding_priority
FROM all_programmes a
CROSS JOIN baseline b
ORDER BY funding_priority;
-- INSIGHT: fleet maintenance ranks first — 15.0% of ALL breaches removed, by
--          fixing 32.6% of the breaches inside its own scope. Batching
--          discipline is second at 13.2% and is the most surgical of the four
--          (it clears 76.8% of breaches in its scope from only 2,346 orders).
--          Partner coaching, the intuitive answer, is third at 3.7%, and
--          festival SLA relief last at 3.5%.
--          Caveat to state out loud: the four scopes overlap, so a combined
--          programme recovers less than the naive 35.4% sum.


/* ---------------------------------------------------------------------------
   Q20b. Where are the breaches actually concentrated?
         The companion view to Q20: not what to fix, but where the damage sits.
   Technique: UNION ALL of overlapping segment shares (segments intentionally
              overlap — this measures exposure, not a partition)
   --------------------------------------------------------------------------- */
WITH b AS (SELECT COUNT(*) FILTER (WHERE is_late) AS total FROM core.fact_orders)
SELECT segment, breaches,
       ROUND(100.0 * breaches / b.total, 1) AS pct_of_all_breaches
FROM (
    SELECT 'Drop distance over 10 km'  AS segment, COUNT(*) FILTER (WHERE is_late) AS breaches
      FROM core.fact_orders WHERE distance_km > 10
    UNION ALL
    SELECT 'Traffic = Jam',             COUNT(*) FILTER (WHERE is_late)
      FROM core.fact_orders WHERE road_traffic_density = 'Jam'
    UNION ALL
    SELECT 'Ordered 19:00-21:59',       COUNT(*) FILTER (WHERE is_late)
      FROM core.fact_orders WHERE order_hour BETWEEN 19 AND 21
    UNION ALL
    SELECT 'Vehicle condition = 0',     COUNT(*) FILTER (WHERE is_late)
      FROM core.fact_orders WHERE vehicle_condition = 0
    UNION ALL
    SELECT 'Batched 2+ orders',         COUNT(*) FILTER (WHERE is_late)
      FROM core.fact_orders WHERE multiple_deliveries >= 2
) seg CROSS JOIN b
ORDER BY breaches DESC;
-- INSIGHT: 64.4% of every breach involves a drop over 10 km, 52.6% happens in
--          Jam traffic and 50.8% falls in the 19:00-21:59 window. These overlap
--          heavily — the archetypal failed order is a long evening drop through
--          jammed traffic, and that single archetype is most of the problem.

\echo '03_analysis_queries.sql complete.'
