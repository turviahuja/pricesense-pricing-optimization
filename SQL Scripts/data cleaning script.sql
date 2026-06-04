-- ============================================================
--  PriceSense · Phase 0: Data Audit & Cleaning
--  Author  : Analytics Taskforce (McKinsey/Bain/BCG style)
--  Purpose : Build a reliable master dataset for downstream
--            pricing sensitivity analysis.
--  Dialect : MySQL 8.0+
-- ============================================================


-- ────────────────────────────────────────────────────────────
-- STEP 1: SOURCE TABLE DEFINITIONS (as loaded from CSV)
-- ────────────────────────────────────────────────────────────

/*
  transactions        (50,150 rows) : order_id, user_id, product_id,
                                      price, quantity, timestamp, channel
  product_metadata    (150 rows)    : product_id, category, claims,
                                      ingredient_tags, pack_size
  consumer_insights   (5,000 rows)  : user_id, persona, trend_affinity,
                                      age_group, gender_identity,
                                      income_bracket, dietary_restriction
  geography_occasion  (47,581 rows) : order_id, state, city_tier, occasion
  competitor_pricing  (720 rows)    : competitor_product_id, price, timestamp
*/


-- ────────────────────────────────────────────────────────────
-- STEP 2: CLEAN PRODUCT METADATA
--   Issues: typo 'Proten Shake', trailing-space 'Protein bar ',
--           4 blank categories, 11 missing ingredient_tags
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW clean_product_metadata AS
SELECT
    product_id,
    CASE
        WHEN TRIM(category) = 'Proten Shake'  THEN 'Protein Shake'
        WHEN TRIM(category) = 'Protein bar'   THEN 'Protein Bar'
        WHEN TRIM(category) = ''              THEN 'Unknown'
        ELSE TRIM(category)
    END                                             AS category,
    claims,
    NULLIF(TRIM(ingredient_tags), '')               AS ingredient_tags,
    pack_size
FROM product_metadata;


-- ────────────────────────────────────────────────────────────
-- STEP 3: CLEAN CONSUMER INSIGHTS
--   Issues: 276 blank persona values (5.5% of users)
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW clean_consumer_insights AS
SELECT
    user_id,
    CASE WHEN TRIM(persona) = '' THEN 'unknown' ELSE TRIM(persona) END  AS persona,
    trend_affinity,
    age_group,
    gender_identity,
    income_bracket,
    dietary_restriction
FROM consumer_insights;


-- ────────────────────────────────────────────────────────────
-- STEP 4: CLEAN GEOGRAPHY & OCCASION
--   Issues: 'NY' → 'New York', 'Calfornia' → 'California',
--           4,691 'Unknown' city tiers (retain, flag)
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW clean_geography AS
SELECT
    order_id,
    CASE
        WHEN state = 'NY'          THEN 'New York'
        WHEN state = 'Calfornia'   THEN 'California'
        ELSE state
    END  AS state,
    CASE
        WHEN city_tier = 'Unknown' THEN NULL
        ELSE city_tier
    END  AS city_tier,
    occasion
FROM geography_occasion;


-- ────────────────────────────────────────────────────────────
-- STEP 5: DEDUPLICATE TRANSACTIONS
--   Issue: 150 exact duplicate order_ids
--   Decision: keep earliest record per order_id
--
--   NOTE: MySQL does not support DISTINCT ON.
--         ROW_NUMBER() is used instead (requires MySQL 8.0+).
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW deduped_transactions AS
WITH ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY timestamp) AS rn
    FROM transactions
)
SELECT
    order_id,
    user_id,
    product_id,
    price,
    quantity,
    timestamp,
    channel
FROM ranked
WHERE rn = 1;


-- ────────────────────────────────────────────────────────────
-- STEP 6: IQR PRICE BOUNDS PER PRODUCT CATEGORY
--   Used to classify price outliers in Step 7
--   Computed on valid (price > 0, qty > 0) transactions only
--
--   NOTE: MySQL does not support PERCENTILE_CONT … WITHIN GROUP.
--         Q1/Q3 are approximated using CUME_DIST() (MySQL 8.0+):
--         the lowest value whose cumulative distribution >= 0.25
--         (or 0.75) is taken as the quartile, matching the
--         nearest-rank method.
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW category_price_bounds AS
WITH valid_prices AS (
    SELECT
        t.order_id,
        p.category,
        t.price
    FROM deduped_transactions t
    JOIN clean_product_metadata p USING (product_id)
    WHERE t.price > 0
      AND t.quantity > 0
),
price_with_dist AS (
    SELECT
        category,
        price,
        CUME_DIST() OVER (PARTITION BY category ORDER BY price) AS cd
    FROM valid_prices
),
percentiles AS (
    SELECT
        category,
        MIN(CASE WHEN cd >= 0.25 THEN price END) AS q1,
        MIN(CASE WHEN cd >= 0.75 THEN price END) AS q3
    FROM price_with_dist
    GROUP BY category
)
SELECT
    category,
    q1,
    q3,
    q3 - q1                        AS iqr,
    q1 - 1.5 * (q3 - q1)          AS lower_bound,
    q3 + 1.5 * (q3 - q1)          AS upper_bound
FROM percentiles;

/* Computed bounds (for reference):
   Electrolyte Drink  : lower=−14.49  upper=49.62
   Healthy Snack      : lower=−11.08  upper=43.52
   Meal Replacement   : lower=−44.30  upper=103.25
   Protein Bar        : lower=−15.54  upper=53.85
   Protein Shake      : lower=−32.51  upper=79.06
   Supplement         : lower=−51.41  upper=114.19
*/


-- ────────────────────────────────────────────────────────────
-- STEP 7: FLAG TRANSACTIONS
--   Mutually exclusive data quality flags in priority order:
--   1. return_refund      — price < 0 AND qty < 0
--   2. zero_price         — price = 0
--   3. bulk_order         — qty > 20 (B2B / gym reseller)
--   4. price_outlier_high — price > category upper bound
--   5. no_geo             — no matching row in geography table
--   6. clean              — passes all checks
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW flagged_transactions AS
SELECT
    t.order_id,
    t.user_id,
    t.product_id,
    t.price,
    t.quantity,
    t.timestamp,
    t.channel,
    p.category,
    g.state,
    g.city_tier,
    g.occasion,
    CASE
        WHEN t.price < 0 AND t.quantity < 0        THEN 'return_refund'
        WHEN t.price = 0                            THEN 'zero_price'
        WHEN t.quantity > 20                        THEN 'bulk_order'
        WHEN t.price > b.upper_bound               THEN 'price_outlier_high'
        WHEN g.order_id IS NULL                     THEN 'no_geo'
        ELSE                                             'clean'
    END  AS data_flag
FROM deduped_transactions t
JOIN clean_product_metadata  p ON t.product_id = p.product_id
LEFT JOIN category_price_bounds b ON p.category = b.category
LEFT JOIN clean_geography    g ON t.order_id   = g.order_id;

/* FLAG DISTRIBUTION (50,000 rows post-dedup):
   clean              41,215  (82.4%)
   price_outlier_high  4,857  ( 9.7%)
   no_geo              2,107  ( 4.2%)
   return_refund       1,063  ( 2.1%)
   bulk_order            509  ( 1.0%)
   zero_price            249  ( 0.5%)
*/


-- ────────────────────────────────────────────────────────────
-- STEP 8: BUILD MASTER ANALYSIS TABLE
--   Joins all 5 sources; enriches with price buckets
--   Downstream analysts filter on data_flag = 'clean'
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW master_pricesense AS
SELECT
    -- Transaction identifiers
    f.order_id,
    f.user_id,
    f.product_id,
    f.timestamp,
    f.channel,
    f.data_flag,

    -- Price & quantity
    f.price,
    f.quantity,
    f.price * f.quantity                    AS revenue,

    -- Price bucket (data-grounded on clean P25/P50/P75)
    CASE
        WHEN f.price <  10             THEN 'A: <10 (entry)'
        WHEN f.price >= 10  AND f.price < 20  THEN 'B: 10–20 (mass)'
        WHEN f.price >= 20  AND f.price < 35  THEN 'C: 20–35 (mid)'
        WHEN f.price >= 35  AND f.price < 55  THEN 'D: 35–55 (premium)'
        WHEN f.price >= 55             THEN 'E: 55+ (luxury)'
    END  AS price_bucket,

    -- Product attributes
    f.category,
    pm.claims,
    pm.ingredient_tags,
    pm.pack_size,

    -- Consumer attributes
    ci.persona,
    ci.trend_affinity,
    ci.age_group,
    ci.income_bracket,
    ci.dietary_restriction,

    -- Geographic & occasion context
    f.state,
    f.city_tier,
    f.occasion

FROM flagged_transactions f
JOIN clean_product_metadata  pm ON f.product_id = pm.product_id
JOIN clean_consumer_insights ci ON f.user_id    = ci.user_id;


-- ────────────────────────────────────────────────────────────
-- STEP 9: CLEAN COMPETITOR PRICING TABLE
--   Issue: 58 null prices (8.1%); forward-fill not appropriate
--   for sparse time series — drop null rows
--
--   NOTE: :: cast operator replaced with CAST().
--         CAST(… AS TEXT) replaced with CAST(… AS CHAR).
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW clean_competitor_pricing AS
SELECT
    competitor_product_id,
    CAST(price AS DECIMAL(10,2))  AS price,
    CAST(timestamp AS DATE)       AS price_date
FROM competitor_pricing
WHERE price IS NOT NULL
  AND TRIM(CAST(price AS CHAR)) != '';

/* Result: 662 rows (58 dropped) across 60 competitor products
   Date range: 2025-04-24 to 2026-04-24
   Price range: $9.66 – $59.18, median $29.37
*/


-- ────────────────────────────────────────────────────────────
-- VALIDATION QUERY — run to confirm master dataset integrity
-- ────────────────────────────────────────────────────────────

SELECT
    data_flag,
    COUNT(*)                                                      AS n_rows,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)           AS pct
FROM master_pricesense
GROUP BY data_flag
ORDER BY n_rows DESC;

-- Expected output:
-- data_flag           | n_rows | pct
-- clean               | 41,215 | 82.4
-- price_outlier_high  |  4,857 |  9.7
-- no_geo              |  2,107 |  4.2
-- return_refund       |  1,063 |  2.1
-- bulk_order          |    509 |  1.0
-- zero_price          |    249 |  0.5


-- ────────────────────────────────────────────────────────────
-- USAGE TEMPLATE FOR DOWNSTREAM ANALYSTS
-- ────────────────────────────────────────────────────────────

-- Core demand analysis (Phase 1):
-- SELECT * FROM master_pricesense WHERE data_flag = 'clean';

-- Geo-enriched analysis (Phase 2):
-- SELECT * FROM master_pricesense
-- WHERE data_flag = 'clean' AND state IS NOT NULL AND city_tier IS NOT NULL;

-- Segment-specific cuts:
-- SELECT * FROM master_pricesense
-- WHERE data_flag = 'clean' AND persona IN ('fitness','budget','premium');

-- Returns analysis (separate workstream):
-- SELECT * FROM master_pricesense WHERE data_flag = 'return_refund';

-- Bulk/B2B analysis:
-- SELECT * FROM master_pricesense WHERE data_flag = 'bulk_order';
