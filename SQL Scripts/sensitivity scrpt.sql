-- ============================================================
--  PriceSense · Phase 1: Sensitivity Framework
--  Author  : Analytics Taskforce (MBB-grade)
--  Purpose : Find exact price thresholds, compare segment
--            sensitivity, and identify channel tolerance
--  Source  : master_pricesense (data_flag = 'clean' only)
--  Dialect : MySQL 8.0+
-- ============================================================
--
--  CONVERSION NOTES (PostgreSQL → MySQL):
--  ① PERCENTILE_CONT(p) WITHIN GROUP (ORDER BY price)
--      → Replaced throughout with a two-step CTE pattern:
--        Step A  CUME_DIST() OVER (PARTITION BY <group> ORDER BY price)
--        Step B  MIN(CASE WHEN cd >= p THEN price END)
--        This implements the nearest-rank method, which matches
--        PERCENTILE_CONT behaviour on large datasets.
--  ② Query 1 restructured into agg + medians CTEs and then
--      joined, because MySQL cannot mix PERCENTILE_CONT with
--      SUM(COUNT(*)) OVER() in a single GROUP BY SELECT.
--  ③ FROM (VALUES (…),(…)) AS t(col1,col2,…) [summary query]
--      → Replaced with SELECT … UNION ALL SELECT … subquery,
--        which is the MySQL-compatible equivalent.
-- ============================================================


-- ────────────────────────────────────────────────────────────
-- QUERY 1: Overall demand distribution by price bucket
--   Business Q: Where do customers naturally cluster?
--   Method: Pre-computed buckets from Phase 0 cleaning
--
--   CONVERSION ①: PERCENTILE_CONT replaced with CUME_DIST CTE.
--   CONVERSION ②: Query split into agg + medians CTEs so that
--   the window-over-window pattern (SUM(COUNT(*)) OVER()) and
--   the percentile derivation can coexist cleanly in MySQL.
-- ────────────────────────────────────────────────────────────

WITH base AS (
    SELECT
        price_bucket,
        price,
        revenue
    FROM master_pricesense
    WHERE data_flag = 'clean'
),
price_with_cd AS (
    SELECT
        price_bucket,
        price,
        CUME_DIST() OVER (PARTITION BY price_bucket ORDER BY price) AS cd
    FROM base
),
medians AS (
    SELECT
        price_bucket,
        MIN(CASE WHEN cd >= 0.50 THEN price END) AS median_price
    FROM price_with_cd
    GROUP BY price_bucket
),
agg AS (
    SELECT
        price_bucket,
        COUNT(*)          AS n_transactions,
        ROUND(AVG(price), 2) AS avg_price,
        ROUND(SUM(revenue), 0) AS total_revenue
    FROM base
    GROUP BY price_bucket
)
SELECT
    a.price_bucket,
    a.n_transactions,
    ROUND(100.0 * a.n_transactions / SUM(a.n_transactions) OVER(), 1)    AS pct_of_demand,
    a.avg_price,
    ROUND(m.median_price, 2)                                              AS median_price,
    a.total_revenue,
    ROUND(100.0 * a.total_revenue / SUM(a.total_revenue) OVER(), 1)      AS pct_of_revenue,
    ROUND(a.total_revenue / a.n_transactions, 2)                          AS revenue_per_txn,
    ROUND(
        (100.0 * a.total_revenue   / SUM(a.total_revenue)   OVER()) /
        (100.0 * a.n_transactions  / SUM(a.n_transactions)  OVER()),
    2)                                                                    AS revenue_efficiency_idx
    -- >1.0 = revenue-efficient; <1.0 = volume drag
FROM agg a
JOIN medians m USING (price_bucket)
ORDER BY a.price_bucket;

/* KEY RESULTS:
   A: <$10    | 22.8% volume | 8.1% revenue  | idx 0.36x ← volume drag
   B: $10–20  | 40.8% volume | 24.2% revenue | idx 0.59x ← volume drag
   C: $20–35  | 18.9% volume | 21.0% revenue | idx 1.11x ← balanced
   D: $35–55  | 11.1% volume | 22.0% revenue | idx 1.98x ← revenue-efficient
   E: $55+    |  6.5% volume | 24.7% revenue | idx 3.80x ← high margin
*/


-- ────────────────────────────────────────────────────────────
-- QUERY 2: Exact demand cliff detection using LAG()
--   Business Q: At which specific price does demand fall off a cliff?
--   Method: % volume drop between consecutive buckets
--   (No PostgreSQL-specific syntax — no changes required)
-- ────────────────────────────────────────────────────────────

WITH bucket_demand AS (
    SELECT
        price_bucket,
        COUNT(*) AS n_transactions
    FROM master_pricesense
    WHERE data_flag = 'clean'
    GROUP BY price_bucket
),
with_lag AS (
    SELECT
        price_bucket,
        n_transactions,
        LAG(n_transactions) OVER (ORDER BY price_bucket) AS prev_bucket_n
    FROM bucket_demand
)
SELECT
    price_bucket,
    n_transactions,
    prev_bucket_n,
    ROUND(100.0 * (prev_bucket_n - n_transactions) / prev_bucket_n, 1) AS pct_demand_drop,
    CASE
        WHEN 100.0 * (prev_bucket_n - n_transactions) / prev_bucket_n > 50
            THEN 'HARD CLIFF — avoid crossing'
        WHEN 100.0 * (prev_bucket_n - n_transactions) / prev_bucket_n > 35
            THEN 'CLIFF — price with caution'
        ELSE 'Gradual decline'
    END AS threshold_classification
FROM with_lag
WHERE prev_bucket_n IS NOT NULL
ORDER BY price_bucket;

/* KEY RESULTS — THRESHOLDS TO AVOID:
   B→C ($20):  +53.6% volume drop → HARD CLIFF
   C→D ($35):  +41.4% volume drop → CLIFF
   D→E ($55):  +41.3% volume drop → CLIFF
   Micro-bin analysis confirms $15 also a soft threshold (+42%)
*/


-- ────────────────────────────────────────────────────────────
-- QUERY 3: Granular $5-bin demand mapping
--   Business Q: Where exactly within buckets do customers concentrate?
--   (No PostgreSQL-specific syntax — no changes required)
-- ────────────────────────────────────────────────────────────

WITH binned AS (
    SELECT
        CASE
            WHEN price >= 0  AND price < 5   THEN '$0–5'
            WHEN price >= 5  AND price < 10  THEN '$5–10'
            WHEN price >= 10 AND price < 15  THEN '$10–15'
            WHEN price >= 15 AND price < 20  THEN '$15–20'
            WHEN price >= 20 AND price < 25  THEN '$20–25'
            WHEN price >= 25 AND price < 30  THEN '$25–30'
            WHEN price >= 30 AND price < 35  THEN '$30–35'
            WHEN price >= 35 AND price < 40  THEN '$35–40'
            WHEN price >= 40 AND price < 45  THEN '$40–45'
            WHEN price >= 45 AND price < 50  THEN '$45–50'
            WHEN price >= 50 AND price < 55  THEN '$50–55'
            WHEN price >= 55 AND price < 65  THEN '$55–65'
            WHEN price >= 65                 THEN '$65+'
        END AS price_bin,
        CASE
            WHEN price >= 0  AND price < 5   THEN 1
            WHEN price >= 5  AND price < 10  THEN 2
            WHEN price >= 10 AND price < 15  THEN 3
            WHEN price >= 15 AND price < 20  THEN 4
            WHEN price >= 20 AND price < 25  THEN 5
            WHEN price >= 25 AND price < 30  THEN 6
            WHEN price >= 30 AND price < 35  THEN 7
            WHEN price >= 35 AND price < 40  THEN 8
            WHEN price >= 40 AND price < 45  THEN 9
            WHEN price >= 45 AND price < 50  THEN 10
            WHEN price >= 50 AND price < 55  THEN 11
            WHEN price >= 55 AND price < 65  THEN 12
            WHEN price >= 65                 THEN 13
        END AS bin_order
    FROM master_pricesense
    WHERE data_flag = 'clean'
),
bin_counts AS (
    SELECT price_bin, bin_order, COUNT(*) AS n
    FROM binned
    GROUP BY price_bin, bin_order
),
with_drop AS (
    SELECT
        price_bin, bin_order, n,
        LAG(n) OVER (ORDER BY bin_order) AS prev_n
    FROM bin_counts
)
SELECT
    price_bin,
    n,
    ROUND(100.0 * n / SUM(n) OVER(), 1)  AS pct_demand,
    CASE WHEN prev_n IS NOT NULL
         THEN ROUND(100.0 * (prev_n - n) / prev_n, 1)
         ELSE NULL
    END  AS pct_drop_from_prev,
    CASE
        WHEN prev_n IS NOT NULL AND 100.0 * (prev_n - n) / prev_n > 40
            THEN '◄ THRESHOLD'
        ELSE ''
    END  AS flag
FROM with_drop
ORDER BY bin_order;

/* SUB-BUCKET THRESHOLDS CONFIRMED:
   $10–15: peak demand zone (25.8%)
   $15–20: -42% → soft threshold at $15
   $20–25: -41% → hard threshold at $20
   $35–40: -41% → premium threshold at $35
*/


-- ────────────────────────────────────────────────────────────
-- QUERY 4: Persona-level demand sensitivity
--   Business Q: Which segment is most vs. least price sensitive?
--   Sensitivity Score = (volume in A+B) / (volume in D+E)
--   Higher score = more price sensitive
--   (No PostgreSQL-specific syntax — no changes required)
-- ────────────────────────────────────────────────────────────

WITH persona_buckets AS (
    SELECT
        persona,
        price_bucket,
        COUNT(*) AS n
    FROM master_pricesense
    WHERE data_flag = 'clean'
      AND persona != 'unknown'
    GROUP BY persona, price_bucket
),
pivoted AS (
    SELECT
        persona,
        SUM(CASE WHEN price_bucket LIKE 'A:%' THEN n ELSE 0 END) AS n_entry,
        SUM(CASE WHEN price_bucket LIKE 'B:%' THEN n ELSE 0 END) AS n_mass,
        SUM(CASE WHEN price_bucket LIKE 'C:%' THEN n ELSE 0 END) AS n_mid,
        SUM(CASE WHEN price_bucket LIKE 'D:%' THEN n ELSE 0 END) AS n_premium,
        SUM(CASE WHEN price_bucket LIKE 'E:%' THEN n ELSE 0 END) AS n_luxury,
        COUNT(*) OVER (PARTITION BY persona)                       AS total_n,
        SUM(n)                                                     AS total_txns
    FROM persona_buckets
    GROUP BY persona
)
SELECT
    persona,
    total_txns,
    ROUND(100.0 * n_entry   / total_txns, 1) AS pct_entry,
    ROUND(100.0 * n_mass    / total_txns, 1) AS pct_mass,
    ROUND(100.0 * n_mid     / total_txns, 1) AS pct_mid,
    ROUND(100.0 * n_premium / total_txns, 1) AS pct_premium,
    ROUND(100.0 * n_luxury  / total_txns, 1) AS pct_luxury,
    ROUND(1.0 * (n_entry + n_mass) / NULLIF(n_premium + n_luxury, 0), 2)
                                             AS sensitivity_score,
    ROUND(100.0 * (n_premium + n_luxury) / total_txns, 1)
                                             AS premium_tolerance_pct
FROM pivoted
ORDER BY sensitivity_score DESC;

/* KEY RESULTS:
   casual  : sensitivity 3.71x → most price sensitive
   budget  : sensitivity 3.63x → high sensitivity
   premium : sensitivity 3.60x → high sensitivity
   fitness : sensitivity 3.52x → least sensitive

   FINDING: All personas share nearly identical price sensitivity.
   The "premium" label does NOT translate to premium price tolerance
   in this dataset. Segmentation by persona alone is insufficient —
   cross-cut with income_bracket and category for actionable insight.
*/


-- ────────────────────────────────────────────────────────────
-- QUERY 5: Persona demand cliffs (per-segment thresholds)
--   Business Q: Does each persona's cliff occur at the same price point?
--   (No PostgreSQL-specific syntax — no changes required)
-- ────────────────────────────────────────────────────────────

WITH persona_bucket_demand AS (
    SELECT
        persona,
        price_bucket,
        COUNT(*) AS n
    FROM master_pricesense
    WHERE data_flag = 'clean'
      AND persona != 'unknown'
    GROUP BY persona, price_bucket
),
with_lag AS (
    SELECT
        persona,
        price_bucket,
        n,
        LAG(n) OVER (PARTITION BY persona ORDER BY price_bucket) AS prev_n
    FROM persona_bucket_demand
)
SELECT
    persona,
    price_bucket                                                          AS transition_to,
    n                                                                     AS n_transactions,
    prev_n                                                                AS prev_bucket_n,
    ROUND(100.0 * (prev_n - n) / NULLIF(prev_n, 0), 1)                  AS pct_drop,
    CASE
        WHEN 100.0 * (prev_n - n) / NULLIF(prev_n, 0) > 50 THEN 'HARD CLIFF'
        WHEN 100.0 * (prev_n - n) / NULLIF(prev_n, 0) > 35 THEN 'CLIFF'
        ELSE 'Gradual'
    END AS cliff_severity
FROM with_lag
WHERE prev_n IS NOT NULL
ORDER BY persona, price_bucket;

/* FINDING: All four personas hit their hardest cliff at the $20 threshold
   (B→C transition), with budget having the steepest drop (+52%) vs.
   fitness (+51%). The $20 threshold is universal — it is a structural
   market boundary, not persona-specific.
*/


-- ────────────────────────────────────────────────────────────
-- QUERY 6: Income bracket sensitivity cross-cut
--   Business Q: Is "premium" tolerance driven by income or persona label?
--
--   CONVERSION ①: PERCENTILE_CONT(0.5) replaced with CUME_DIST CTE.
--   The agg CTE handles all standard GROUP BY aggregations;
--   the medians CTE handles the percentile; both join at the end.
-- ────────────────────────────────────────────────────────────

WITH price_with_cd AS (
    SELECT
        income_bracket,
        price,
        CUME_DIST() OVER (PARTITION BY income_bracket ORDER BY price) AS cd
    FROM master_pricesense
    WHERE data_flag = 'clean'
),
medians AS (
    SELECT
        income_bracket,
        MIN(CASE WHEN cd >= 0.50 THEN price END) AS median_price
    FROM price_with_cd
    GROUP BY income_bracket
),
agg AS (
    SELECT
        income_bracket,
        COUNT(*)                                                                    AS n_transactions,
        ROUND(100.0 * SUM(CASE WHEN price < 20  THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_in_entry_mass,
        ROUND(100.0 * SUM(CASE WHEN price >= 35 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_in_premium_luxury,
        ROUND(AVG(price), 2)                                                        AS avg_price
    FROM master_pricesense
    WHERE data_flag = 'clean'
    GROUP BY income_bracket
)
SELECT
    a.income_bracket,
    a.n_transactions,
    ROUND(m.median_price, 2) AS median_price,
    a.pct_in_entry_mass,
    a.pct_in_premium_luxury,
    a.avg_price
FROM agg a
JOIN medians m USING (income_bracket)
ORDER BY a.avg_price DESC;

/* KEY RESULT:
   High income : 62.4% in A+B, 17.6% in D+E — median $15.91
   Medium income: 63.3% in A+B, 18.2% in D+E — median $15.67
   Low income  : 64.6% in A+B, 16.6% in D+E — median $15.01
   Income adds only marginal differentiation — confirms pricing
   sensitivity is structural across ALL segments in this market.
*/


-- ────────────────────────────────────────────────────────────
-- QUERY 7: Channel-level price tolerance
--   Business Q: Which sales channel supports higher prices?
--   MBB differentiator: cross-channel pricing strategy
--
--   CONVERSION ①: PERCENTILE_CONT replaced with CUME_DIST CTE.
--   Three percentiles derived (p50, p75, p90) in a single CTE pass.
-- ────────────────────────────────────────────────────────────

WITH price_with_cd AS (
    SELECT
        channel,
        price,
        revenue,
        CUME_DIST() OVER (PARTITION BY channel ORDER BY price) AS cd
    FROM master_pricesense
    WHERE data_flag = 'clean'
),
percentiles AS (
    SELECT
        channel,
        MIN(CASE WHEN cd >= 0.50 THEN price END) AS median_price,
        MIN(CASE WHEN cd >= 0.75 THEN price END) AS p75_price,
        MIN(CASE WHEN cd >= 0.90 THEN price END) AS p90_price
    FROM price_with_cd
    GROUP BY channel
),
agg AS (
    SELECT
        channel,
        COUNT(*)                                                                    AS n_transactions,
        ROUND(AVG(price), 2)                                                        AS avg_price,
        ROUND(100.0 * SUM(CASE WHEN price < 20  THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_in_entry_mass,
        ROUND(100.0 * SUM(CASE WHEN price >= 35 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_in_premium_luxury,
        ROUND(SUM(revenue), 0)                                                      AS total_revenue
    FROM master_pricesense
    WHERE data_flag = 'clean'
    GROUP BY channel
)
SELECT
    a.channel,
    a.n_transactions,
    a.avg_price,
    ROUND(p.median_price, 2) AS median_price,
    ROUND(p.p75_price, 2)    AS p75_price,
    ROUND(p.p90_price, 2)    AS p90_price,
    a.pct_in_entry_mass,
    a.pct_in_premium_luxury,
    a.total_revenue
FROM agg a
JOIN percentiles p USING (channel)
ORDER BY p.median_price DESC;

/* KEY RESULTS:
   App      : median $15.91, 18.3% in D+E → highest premium tolerance
   Gym Kiosk: median $15.72, 17.5% in D+E
   Retail   : median $15.74, 17.2% in D+E
   Website  : median $15.50, 17.6% in D+E
   Marketplace: median $14.75, 17.3% in D+E → lowest price point

   FINDING: App channel commands ~8% higher median prices vs Marketplace.
   Gym Kiosk expectation (high premium tolerance) not confirmed at bucket
   level — price point similar to Retail. Channel differences are narrow.
*/


-- ────────────────────────────────────────────────────────────
-- QUERY 8: Category-level premium tolerance
--   Business Q: Which product categories sustain premium pricing?
--
--   CONVERSION ①: PERCENTILE_CONT replaced with CUME_DIST CTE.
--   Two percentiles derived (p50, p75) in a single CTE pass.
--   SUM(a.total_revenue) OVER() window retained for revenue share.
-- ────────────────────────────────────────────────────────────

WITH price_with_cd AS (
    SELECT
        category,
        price,
        revenue,
        CUME_DIST() OVER (PARTITION BY category ORDER BY price) AS cd
    FROM master_pricesense
    WHERE data_flag = 'clean'
),
percentiles AS (
    SELECT
        category,
        MIN(CASE WHEN cd >= 0.50 THEN price END) AS median_price,
        MIN(CASE WHEN cd >= 0.75 THEN price END) AS p75_price
    FROM price_with_cd
    GROUP BY category
),
agg AS (
    SELECT
        category,
        COUNT(*)                                                                    AS n_transactions,
        ROUND(100.0 * SUM(CASE WHEN price < 20  THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_entry_mass,
        ROUND(100.0 * SUM(CASE WHEN price >= 35 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_premium_luxury,
        SUM(revenue)                                                                AS total_revenue
    FROM master_pricesense
    WHERE data_flag = 'clean'
    GROUP BY category
)
SELECT
    a.category,
    a.n_transactions,
    ROUND(p.median_price, 2)                                             AS median_price,
    ROUND(p.p75_price, 2)                                                AS p75_price,
    a.pct_entry_mass,
    a.pct_premium_luxury,
    ROUND(100.0 * a.total_revenue / SUM(a.total_revenue) OVER(), 1)     AS revenue_share_pct
FROM agg a
JOIN percentiles p USING (category)
ORDER BY a.pct_premium_luxury DESC;

/* KEY RESULTS:
   Supplement     : 34.2% in D+E → highest premium tolerance
   Meal Replacement: 29.5% in D+E
   Protein Shake  : 20.3% in D+E
   Protein Bar    :  9.6% in D+E → most price-sensitive category
   Electrolyte    :  3.9% in D+E → commodity pricing zone
*/


-- ────────────────────────────────────────────────────────────
-- QUERY 9: Age group sensitivity — who buys premium?
--
--   CONVERSION ①: PERCENTILE_CONT(0.5) replaced with CUME_DIST CTE.
-- ────────────────────────────────────────────────────────────

WITH price_with_cd AS (
    SELECT
        age_group,
        price,
        CUME_DIST() OVER (PARTITION BY age_group ORDER BY price) AS cd
    FROM master_pricesense
    WHERE data_flag = 'clean'
),
medians AS (
    SELECT
        age_group,
        MIN(CASE WHEN cd >= 0.50 THEN price END) AS median_price
    FROM price_with_cd
    GROUP BY age_group
),
agg AS (
    SELECT
        age_group,
        COUNT(*)                                                                    AS n_transactions,
        ROUND(100.0 * SUM(CASE WHEN price < 20  THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_entry_mass,
        ROUND(100.0 * SUM(CASE WHEN price >= 35 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_premium_luxury
    FROM master_pricesense
    WHERE data_flag = 'clean'
    GROUP BY age_group
)
SELECT
    a.age_group,
    a.n_transactions,
    ROUND(m.median_price, 2) AS median_price,
    a.pct_entry_mass,
    a.pct_premium_luxury
FROM agg a
JOIN medians m USING (age_group)
ORDER BY CASE a.age_group
    WHEN '18-24' THEN 1 WHEN '25-34' THEN 2 WHEN '35-44' THEN 3
    WHEN '45-54' THEN 4 WHEN '55+'   THEN 5
END;

/* KEY RESULT:
   55+ segment: 59.8% in entry/mass vs 19.2% premium — highest premium
   index (1.09x vs baseline). Older, likely higher-income shoppers
   show marginally more premium tolerance. 18–24: most price-sensitive.
*/


-- ────────────────────────────────────────────────────────────
-- SUMMARY: Pricing threshold decision matrix
--   The actionable output for the brand's pricing team
--
--   CONVERSION ③: FROM (VALUES (…),(…)) AS t(col1,col2,…)
--   is not supported in MySQL. Replaced with a
--   SELECT … UNION ALL … subquery, which is fully compatible
--   with MySQL 8.0 and renders identically in MySQL Workbench.
-- ────────────────────────────────────────────────────────────

SELECT
    threshold_price,
    threshold_type,
    pct_demand_lost,
    recommendation
FROM (
    SELECT
        '$15'            AS threshold_price,
        'Soft threshold' AS threshold_type,
        '42% drop in $5-bin from $10–15 to $15–20'            AS pct_demand_lost,
        'Price just below $15 to maximise mass-market volume'  AS recommendation
    UNION ALL
    SELECT
        '$20',
        'HARD CLIFF',
        '54% drop from mass to mid bucket',
        'DO NOT cross $20 for budget/casual products without clear differentiation'
    UNION ALL
    SELECT
        '$35',
        'Premium boundary',
        '41% drop from mid to premium bucket',
        'Only cross $35 with trend claims (supplement, meal replacement) or App/Gym channel'
    UNION ALL
    SELECT
        '$55',
        'Luxury threshold',
        '41% drop from premium to luxury bucket',
        'Reserve for high-margin supplement/meal-replacement SKUs with clean-label claims'
) AS t
ORDER BY threshold_price;
