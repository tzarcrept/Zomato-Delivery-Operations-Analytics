/* ============================================================================
   FILE     : 01_schema.sql
   PROJECT  : Zomato Delivery Operations Analytics
   PURPOSE  : Create the database schema — one raw landing (staging) table that
              mirrors the CSV exactly, plus a normalised analytical model.
   ENGINE   : PostgreSQL 13+
   RUN      : psql -d zomato_ops -f 01_schema.sql
   ----------------------------------------------------------------------------
   DESIGN NOTES
   ------------
   The source file is a single flat, denormalised extract (45,584 rows, 20
   columns). It is loaded AS-IS into `staging.stg_deliveries`, where every
   column is TEXT. This is deliberate: the raw file contains mixed time
   formats, the literal string 'NaN', sign-flipped coordinates and out-of-range
   values. Typed columns would reject the load before we ever got a chance to
   profile the damage. Land raw -> profile -> clean -> conform.

   The analytical model is a star schema:

       dim_city ──┐
                  ├── dim_restaurant ──┐
       dim_city ──┘                    ├── fact_orders
                  └── dim_partner ─────┘
                                       └── dim_date

   `Delivery_person_ID` is a composite business key that encodes three levels
   of the hierarchy, e.g. 'PUNERES13DEL03':
       PUNE  -> city code
       RES13 -> restaurant / dispatch hub within that city
       DEL03 -> delivery partner index within that hub
   The normalisation in 02_cleaning.sql shreds this key into three dimensions.
   ========================================================================== */

-- ---------------------------------------------------------------------------
-- 0. Schemas
-- ---------------------------------------------------------------------------
DROP SCHEMA IF EXISTS staging CASCADE;
DROP SCHEMA IF EXISTS core    CASCADE;
DROP SCHEMA IF EXISTS mart    CASCADE;

CREATE SCHEMA staging;   -- raw landing zone, all TEXT
CREATE SCHEMA core;      -- cleaned, typed, normalised
CREATE SCHEMA mart;      -- BI-facing views (built in 04_views.sql)

COMMENT ON SCHEMA staging IS 'Raw CSV landing zone. All columns TEXT. Never queried by BI.';
COMMENT ON SCHEMA core    IS 'Cleaned, typed, normalised star schema. Single source of truth.';
COMMENT ON SCHEMA mart    IS 'Denormalised views for dashboards and ad-hoc analysis.';


-- ---------------------------------------------------------------------------
-- 1. Staging — mirrors Zomato_Dataset.csv column-for-column
-- ---------------------------------------------------------------------------
CREATE TABLE staging.stg_deliveries (
    id                            TEXT,
    delivery_person_id            TEXT,
    delivery_person_age           TEXT,
    delivery_person_ratings       TEXT,
    restaurant_latitude           TEXT,
    restaurant_longitude          TEXT,
    delivery_location_latitude    TEXT,
    delivery_location_longitude   TEXT,
    order_date                    TEXT,
    time_ordered                  TEXT,
    time_order_picked             TEXT,
    weather_conditions            TEXT,
    road_traffic_density          TEXT,
    vehicle_condition             TEXT,
    type_of_order                 TEXT,
    type_of_vehicle               TEXT,
    multiple_deliveries           TEXT,
    festival                      TEXT,
    city                          TEXT,
    time_taken_min                TEXT
);

COMMENT ON TABLE staging.stg_deliveries IS
    'Verbatim copy of Zomato_Dataset.csv. 45,584 rows expected after load.';


-- ---------------------------------------------------------------------------
-- 2. Reference table — SLA policy
--    Externalising the SLA into a table (rather than hard-coding 30 in every
--    query) means the whole analysis can be re-run under a different service
--    promise by updating one row. This is how SLA logic is handled in
--    production analytics stacks.
-- ---------------------------------------------------------------------------
CREATE TABLE core.sla_policy (
    city_type        TEXT PRIMARY KEY,
    sla_minutes      SMALLINT NOT NULL CHECK (sla_minutes > 0),
    effective_from   DATE     NOT NULL DEFAULT DATE '2022-01-01'
);

INSERT INTO core.sla_policy (city_type, sla_minutes) VALUES
    ('Metropolitian', 30),
    ('Urban',         30),
    ('Semi-Urban',    45),
    ('Unknown',       30);

COMMENT ON TABLE core.sla_policy IS
    'Promised delivery window by city class. Semi-Urban gets a longer promise '
    'because of structurally longer drop distances.';


-- ---------------------------------------------------------------------------
-- 3. Dimensions
-- ---------------------------------------------------------------------------
CREATE TABLE core.dim_city (
    city_id      SMALLSERIAL PRIMARY KEY,
    city_code    TEXT NOT NULL UNIQUE,      -- 'PUNE', 'BANG', 'INDO' ...
    city_name    TEXT NOT NULL,             -- 'Pune', 'Bangalore', 'Indore' ...
    city_tier    SMALLINT                   -- 1 / 2 / 3, analyst-assigned
);

CREATE TABLE core.dim_restaurant (
    restaurant_id       SERIAL PRIMARY KEY,
    restaurant_code     TEXT     NOT NULL UNIQUE,   -- 'PUNERES13'
    city_id             SMALLINT NOT NULL REFERENCES core.dim_city(city_id),
    hub_latitude        NUMERIC(9,6),               -- median of valid pickups
    hub_longitude       NUMERIC(9,6)
);

CREATE TABLE core.dim_partner (
    partner_id          SERIAL PRIMARY KEY,
    partner_code        TEXT     NOT NULL UNIQUE,   -- 'PUNERES13DEL03'
    restaurant_id       INT      NOT NULL REFERENCES core.dim_restaurant(restaurant_id),
    city_id             SMALLINT NOT NULL REFERENCES core.dim_city(city_id),
    partner_age         SMALLINT CHECK (partner_age BETWEEN 18 AND 65),
    partner_rating      NUMERIC(2,1) CHECK (partner_rating BETWEEN 1.0 AND 5.0),
    primary_vehicle     TEXT,
    age_band            TEXT,
    rating_band         TEXT
);

CREATE TABLE core.dim_date (
    date_key        DATE PRIMARY KEY,
    day_of_week     SMALLINT NOT NULL,   -- 0 = Sunday
    day_name        TEXT     NOT NULL,
    week_of_year    SMALLINT NOT NULL,
    month_num       SMALLINT NOT NULL,
    month_name      TEXT     NOT NULL,
    is_weekend      BOOLEAN  NOT NULL
);


-- ---------------------------------------------------------------------------
-- 4. Fact table
--    Grain: one row per delivered order.
--    Degenerate dimensions (weather, traffic, order type) are kept on the fact
--    row rather than spun into their own tables — they are low-cardinality
--    order-time conditions, not slowly-changing entities.
-- ---------------------------------------------------------------------------
CREATE TABLE core.fact_orders (
    order_id              TEXT     PRIMARY KEY,          -- '0xcdcd'
    restaurant_id         INT      NOT NULL REFERENCES core.dim_restaurant(restaurant_id),
    partner_id            INT      NOT NULL REFERENCES core.dim_partner(partner_id),
    city_id               SMALLINT NOT NULL REFERENCES core.dim_city(city_id),
    order_date            DATE     NOT NULL REFERENCES core.dim_date(date_key),

    -- Timestamps ------------------------------------------------------------
    order_ts              TIMESTAMP,      -- NULL where source time was unusable
    pickup_ts             TIMESTAMP,
    delivered_ts          TIMESTAMP,

    -- Measures --------------------------------------------------------------
    prep_wait_min         SMALLINT,       -- order placed -> picked up
    time_taken_min        SMALLINT NOT NULL,
    distance_km           NUMERIC(6,2),

    -- Order-time conditions (degenerate dimensions) -------------------------
    weather_conditions    TEXT,
    road_traffic_density  TEXT,
    vehicle_condition     SMALLINT,
    type_of_order         TEXT,
    type_of_vehicle       TEXT,
    multiple_deliveries   SMALLINT,
    is_festival           BOOLEAN,
    city_type             TEXT,

    -- Derived analytical attributes -----------------------------------------
    order_hour            SMALLINT,
    day_part              TEXT,           -- Breakfast / Lunch / Evening / Dinner / Late Night
    sla_minutes           SMALLINT,
    sla_breach_min        SMALLINT,       -- positive = minutes late
    is_late               BOOLEAN,
    speed_kmph            NUMERIC(6,2),

    -- Data-quality lineage --------------------------------------------------
    has_valid_geo         BOOLEAN NOT NULL DEFAULT FALSE,
    has_valid_times       BOOLEAN NOT NULL DEFAULT FALSE,

    CONSTRAINT chk_time_taken CHECK (time_taken_min BETWEEN 1 AND 300)
);


-- ---------------------------------------------------------------------------
-- 5. Indexes — chosen to match the access patterns in 03_analysis_queries.sql
-- ---------------------------------------------------------------------------
CREATE INDEX idx_fact_date        ON core.fact_orders (order_date);
CREATE INDEX idx_fact_city        ON core.fact_orders (city_id);
CREATE INDEX idx_fact_partner     ON core.fact_orders (partner_id);
CREATE INDEX idx_fact_restaurant  ON core.fact_orders (restaurant_id);
CREATE INDEX idx_fact_late        ON core.fact_orders (is_late) WHERE is_late;
CREATE INDEX idx_fact_traffic     ON core.fact_orders (road_traffic_density, weather_conditions);
CREATE INDEX idx_fact_hour        ON core.fact_orders (order_hour);


-- ---------------------------------------------------------------------------
-- 6. Data-quality audit log — populated by 02_cleaning.sql
-- ---------------------------------------------------------------------------
CREATE TABLE core.dq_audit (
    check_id     SERIAL PRIMARY KEY,
    check_name   TEXT NOT NULL,
    rows_flagged BIGINT NOT NULL,
    rows_total   BIGINT NOT NULL,
    pct_flagged  NUMERIC(5,2) GENERATED ALWAYS AS
                 (ROUND(100.0 * rows_flagged / NULLIF(rows_total,0), 2)) STORED,
    action_taken TEXT,
    checked_at   TIMESTAMP NOT NULL DEFAULT NOW()
);

\echo '01_schema.sql complete — schemas staging / core / mart created.'
