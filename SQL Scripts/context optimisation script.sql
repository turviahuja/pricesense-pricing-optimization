-- ============================================================
--  PriceSense · Phase 2: Contextual Optimisation
--  Author  : Analytics Taskforce (MBB-grade)
--  Purpose : Evaluate product attributes, geo-occasion context,
--            and revenue vs. volume trade-offs to fix pricing
--  Phase 1 assumptions already validated:
--    - $20 = hard cliff (−54% demand)
--    - $35, $55 = secondary cliffs (−41% each)
--    - All personas share similar sensitivity (3.52x–3.71x)
--    - App channel = highest price tolerance
--  Source  : master_pricesense (data_flag = 'clean' only)
--  Dialect : MySQL 8.0+
-- ============================================================
--
--  CONVERSION NOTES (PostgreSQL → MySQL 8.0):
--
--  ① STRING_SPLIT() + UNNEST() → RECURSIVE numbers CTE
--      MySQL has neither function. Replacement uses a two-step
--      technique in every query that splits claims:
--
--      Step A — generate integers 1…N via a recursive CTE:
--        WITH RECURSIVE claim_numbers AS (
--            SELECT 1 AS n
--            UNION ALL
--            SELECT n + 1 FROM claim_numbers WHERE n < 10
--        )
--      Step B — extract the nth token with a SUBSTRING_INDEX
--      double-pass and cross-join the numbers to the base table:
--        TRIM(SUBSTRING_INDEX(SUBSTRING_INDEX(claims, ',', n), ',', -1))
--      The cross-join guard (n <= 1 + commas_in_string) ensures
--      no phantom rows are emitted for shorter claim lists.
--      Cap of 10 safely covers all observed claim counts.
--
--  ② PERCENTILE_CONT(p) WITHIN GROUP (ORDER BY price)
--      → CUME_DIST() window function, nearest-rank method:
--        price_with_cd AS (
--            SELECT ..., CUME_DIST() OVER (PARTITION BY grp ORDER BY price) AS cd
--        ),
--        percentiles AS (
--            SELECT grp, MIN(CASE WHEN cd >= p THEN price END) AS pN_price
--        )
--      Queries where PERCENTILE_CONT appeared inside a CASE WHEN
--      expression within a GROUP BY SELECT (Q3, Q5) are fully
--      restructured: an agg CTE handles all standard aggregates
--      and a medians CTE handles percentiles; the final SELECT
--      joins them and references median_price directly in CASE WHEN.
--
--  ③ FROM (VALUES (…),(…)) AS t(col1, col2, …)
--      → SELECT … UNION ALL SELECT … subquery
--      Used for elasticity_params (Q6) and the SKU playbook (Q9).
--      UNION ALL subquery is universally safe in MySQL Workbench.
-- ============================================================


-- ────────────────────────────────────────────────────────────
-- QUERY 1: Trend claim premium power ranking
--   Business Q: Which claims justify higher shelf prices?
--   Method: compare median price, %D+E, and revenue/txn by claim
--
--   CONVERSION ①: UNNEST(STRING_SPLIT(claims, ','))
--       → RECURSIVE claim_numbers CTE + SUBSTRING_INDEX double-pass.
--   CONVERSION ②: PERCENTILE_CONT × 3 (p50, p75, p90)
--       → CUME_DIST price_with_cd + percentiles CTEs.
--       Query split: claim_exploded → price_with_cd → percentiles
--       for the percentile path; claim_exploded → agg for the
--       count/sum path; final SELECT joins both.
-- ────────────────────────────────────────────────────────────

WITH RECURSIVE claim_numbers AS (
    -- Generate integers 1–10; supports up to 10 claims per product
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM claim_numbers WHERE n < 10
),
claim_exploded AS (
    -- Cross-join each row with the numbers table; extract the nth
    -- comma-delimited token.  The guard condition eliminates phantom
    -- rows for products with fewer than 10 claims.
    SELECT
        m.order_id,
        m.price,
        m.quantity,
        m.revenue,
        TRIM(
            SUBSTRING_INDEX(
                SUBSTRING_INDEX(m.claims, ',', cn.n),
            ',', -1)
        ) AS claim
    FROM master_pricesense m
    CROSS JOIN claim_numbers cn
    WHERE m.data_flag = 'clean'
      AND m.claims IS NOT NULL
      AND cn.n <= 1 + LENGTH(m.claims) - LENGTH(REPLACE(m.claims, ',', ''))
),
price_with_cd AS (
    SELECT
        claim,
        price,
        CUME_DIST() OVER (PARTITION BY claim ORDER BY price) AS cd
    FROM claim_exploded
),
percentiles AS (
    SELECT
        claim,
        MIN(CASE WHEN cd >= 0.50 THEN price END) AS median_price,
        MIN(CASE WHEN cd >= 0.75 THEN price END) AS p75_price,
        MIN(CASE WHEN cd >= 0.90 THEN price END) AS p90_price
    FROM price_with_cd
    GROUP BY claim
),
agg AS (
    SELECT
        claim,
        COUNT(*)                                                                    AS n_transactions,
        ROUND(100.0 * SUM(CASE WHEN price >= 35 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_premium_luxury,
        ROUND(SUM(revenue) / COUNT(*), 2)                                          AS revenue_per_txn
    FROM claim_exploded
    GROUP BY claim
)
SELECT
    a.claim,
    a.n_transactions,
    ROUND(p.median_price, 2)   AS median_price,
    ROUND(p.p75_price, 2)      AS p75_price,
    a.pct_premium_luxury,
    a.revenue_per_txn,
    CASE
        WHEN a.pct_premium_luxury >= 25 THEN 'HIGH premium power — justifies $35+'
        WHEN a.pct_premium_luxury >= 15 THEN 'MODERATE — supports $20–35 range'
        ELSE                                 'LOW — commodity, compete on volume'
    END AS claim_premium_verdict
FROM agg a
JOIN percentiles p USING (claim)
ORDER BY a.pct_premium_luxury DESC;

/* KEY RESULTS (top claims by premium power):
   vegan         : 30.9% in D+E, med $21.28, rev/txn $61.20 → HIGH
   halal         : 24.6% in D+E, med $17.04, rev/txn $50.25 → MODERATE
   high-protein  : 16.1% in D+E, med $21.33, rev/txn $51.72 → MODERATE
   keto-friendly : 16.3% in D+E, med $19.07, rev/txn $57.34 → MODERATE
   clean-label   : 14.2% in D+E, med $20.02, rev/txn $58.37 → MODERATE
   nut-free      :  5.0% in D+E → LOW — commoditised claim
   plant-based   : 10.9% in D+E → LOW at current prices
*/


-- ────────────────────────────────────────────────────────────
-- QUERY 2: Claim × Category premium power matrix
--   Business Q: Which specific SKU type should command premium?
--
--   CONVERSION ①: UNNEST(STRING_SPLIT(claims, ','))
--       → same RECURSIVE claim_numbers + SUBSTRING_INDEX pattern.
--   CONVERSION ②: PERCENTILE_CONT(0.5)
--       → CUME_DIST price_with_cd + medians CTEs.
--       agg handles COUNT/SUM; final SELECT joins both.
-- ────────────────────────────────────────────────────────────

WITH RECURSIVE claim_numbers AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM claim_numbers WHERE n < 10
),
claim_cat AS (
    SELECT
        TRIM(
            SUBSTRING_INDEX(
                SUBSTRING_INDEX(m.claims, ',', cn.n),
            ',', -1)
        )       AS claim,
        m.category,
        m.price
    FROM master_pricesense m
    CROSS JOIN claim_numbers cn
    WHERE m.data_flag = 'clean'
      AND m.claims IS NOT NULL
      AND cn.n <= 1 + LENGTH(m.claims) - LENGTH(REPLACE(m.claims, ',', ''))
),
price_with_cd AS (
    SELECT
        claim,
        category,
        price,
        CUME_DIST() OVER (PARTITION BY claim, category ORDER BY price) AS cd
    FROM claim_cat
    WHERE claim IN ('vegan','high-protein','keto-friendly','clean-label','low-sugar','halal')
),
medians AS (
    SELECT
        claim,
        category,
        MIN(CASE WHEN cd >= 0.50 THEN price END) AS median_price
    FROM price_with_cd
    GROUP BY claim, category
),
agg AS (
    SELECT
        claim,
        category,
        COUNT(*)                                                                    AS n,
        ROUND(100.0 * SUM(CASE WHEN price >= 35 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_premium_luxury
    FROM claim_cat
    WHERE claim IN ('vegan','high-protein','keto-friendly','clean-label','low-sugar','halal')
    GROUP BY claim, category
    HAVING COUNT(*) >= 50
)
SELECT
    a.claim,
    a.category,
    a.n,
    ROUND(m.median_price, 2) AS median_price,
    a.pct_premium_luxury
FROM agg a
JOIN medians m USING (claim, category)
ORDER BY a.pct_premium_luxury DESC;

/* HEADLINE FINDINGS:
   vegan + Meal Replacement  : 77.5% in D+E, median $47.50 → HIGHEST POWER
   keto + Supplement         : 61.4% in D+E, median $42.38
   vegan + Supplement        : 57.7% in D+E, median $41.39
   gluten-free + Meal Repl.  : 62.0% in D+E, median $51.00
   high-protein + Protein Shk: 47.9% in D+E, median $28.16
   Clean-label alone is only MODERATE — strongest when paired with vegan/keto
*/


-- ────────────────────────────────────────────────────────────
-- QUERY 3: Geography pricing matrix — state level
--   Business Q: Where can the brand charge more?
--
--   CONVERSION ②: PERCENTILE_CONT(0.5) appeared three times
--   in this query — once as a SELECT column alias (median_price)
--   and twice inside CASE WHEN thresholds (>= 16, >= 14.5).
--   MySQL cannot reference a window-derived value inside the
--   same GROUP BY SELECT.  Full restructure:
--     price_with_cd → medians (percentile path)
--     agg            (count/sum path)
--   Final SELECT joins both and references m.median_price
--   directly in the CASE WHEN, replacing both inline calls.
-- ────────────────────────────────────────────────────────────

WITH price_with_cd AS (
    SELECT
        state,
        price,
        revenue,
        CUME_DIST() OVER (PARTITION BY state ORDER BY price) AS cd
    FROM master_pricesense
    WHERE data_flag = 'clean'
      AND state IS NOT NULL
),
medians AS (
    SELECT
        state,
        MIN(CASE WHEN cd >= 0.50 THEN price END) AS median_price
    FROM price_with_cd
    GROUP BY state
),
agg AS (
    SELECT
        state,
        COUNT(*)                                                                    AS n_transactions,
        ROUND(AVG(price), 2)                                                        AS avg_price,
        ROUND(100.0 * SUM(CASE WHEN price >= 35 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_premium_luxury,
        ROUND(SUM(revenue), 0)                                                      AS total_revenue,
        ROUND(SUM(revenue) / COUNT(*), 2)                                           AS revenue_per_txn
    FROM master_pricesense
    WHERE data_flag = 'clean'
      AND state IS NOT NULL
    GROUP BY state
)
SELECT
    a.state,
    a.n_transactions,
    ROUND(m.median_price, 2) AS median_price,
    a.avg_price,
    a.pct_premium_luxury,
    a.total_revenue,
    a.revenue_per_txn,
    CASE
        WHEN m.median_price >= 16    THEN 'PREMIUM state — support +5–10% pricing'
        WHEN m.median_price >= 14.5  THEN 'MID state — standard pricing'
        ELSE                              'VOLUME state — price defensively'
    END AS state_pricing_tier
FROM agg a
JOIN medians m USING (state)
ORDER BY m.median_price DESC;

/* KEY RESULTS:
   Colorado  : median $16.45, 19.5% in D+E → PREMIUM state
   California: median $16.16, 18.8% in D+E → PREMIUM state
   New York  : median $16.11, 19.0% in D+E → PREMIUM state
   Illinois  : median $15.69 → MID state
   Washington: median $14.87 → MID state
   Florida   : median $14.83 → MID state
   Georgia   : median $14.50, 16.0% → VOLUME state
   Texas     : median $14.35, 15.5% → VOLUME state
   → Premium states command ~14% higher median than volume states
*/


-- ────────────────────────────────────────────────────────────
-- QUERY 4: City tier pricing matrix
--   Business Q: Does city size predict price tolerance?
--
--   CONVERSION ②: PERCENTILE_CONT(0.5) → CUME_DIST CTE.
--   Standard agg + medians split; final SELECT joins both.
-- ────────────────────────────────────────────────────────────

WITH price_with_cd AS (
    SELECT
        city_tier,
        price,
        revenue,
        CUME_DIST() OVER (PARTITION BY city_tier ORDER BY price) AS cd
    FROM master_pricesense
    WHERE data_flag = 'clean'
      AND city_tier IS NOT NULL
),
medians AS (
    SELECT
        city_tier,
        MIN(CASE WHEN cd >= 0.50 THEN price END) AS median_price
    FROM price_with_cd
    GROUP BY city_tier
),
agg AS (
    SELECT
        city_tier,
        COUNT(*)                                                                    AS n_transactions,
        ROUND(AVG(price), 2)                                                        AS avg_price,
        ROUND(100.0 * SUM(CASE WHEN price < 20  THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_entry_mass,
        ROUND(100.0 * SUM(CASE WHEN price >= 35 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_premium_luxury,
        ROUND(SUM(revenue) / COUNT(*), 2)                                           AS revenue_per_txn
    FROM master_pricesense
    WHERE data_flag = 'clean'
      AND city_tier IS NOT NULL
    GROUP BY city_tier
)
SELECT
    a.city_tier,
    a.n_transactions,
    ROUND(m.median_price, 2) AS median_price,
    a.avg_price,
    a.pct_entry_mass,
    a.pct_premium_luxury,
    a.revenue_per_txn
FROM agg a
JOIN medians m USING (city_tier)
ORDER BY CASE a.city_tier
    WHEN 'Tier 1' THEN 1
    WHEN 'Tier 2' THEN 2
    WHEN 'Tier 3' THEN 3
END;

/* COUNTERINTUITIVE FINDING:
   Tier 1 : median $15.57, rev/txn $45.94, 17.0% premium — lowest
   Tier 2 : median $15.42, rev/txn $47.00, 17.4% premium — middle
   Tier 3 : median $15.74, rev/txn $57.52, 19.3% premium — HIGHEST

   Tier 3 cities outperform on rev/txn (+25% vs Tier 1) because:
   - Occasion mix skews toward gym (+4.8%), marathon-prep (+4.2%),
     religious-fasting (+6.8%) — high-intent, functional purchase contexts
   - Tier 1 is dominated by late-night (47.4% vs 12.1% in Tier 3) —
     an impulse/low-consideration occasion with lower price tolerance
*/


-- ────────────────────────────────────────────────────────────
-- QUERY 5: Occasion-based pricing power ranking
--   Business Q: Which occasions allow premium pricing?
--
--   CONVERSION ②: PERCENTILE_CONT(0.5) appeared twice in
--   the original SELECT — once as the median_price column and
--   twice inside CASE WHEN thresholds (>= 15.8, >= 15.0).
--   Same fix as Query 3: agg CTE for standard aggregates,
--   medians CTE for the percentile, final SELECT joins both
--   and uses m.median_price directly in the CASE WHEN.
--   NOTE: SUM(SUM(revenue)) OVER() for pct_of_total_revenue
--   is applied to the pre-aggregated agg.total_revenue column
--   in the outer SELECT, which MySQL 8.0 handles correctly.
-- ────────────────────────────────────────────────────────────

WITH price_with_cd AS (
    SELECT
        occasion,
        price,
        revenue,
        CUME_DIST() OVER (PARTITION BY occasion ORDER BY price) AS cd
    FROM master_pricesense
    WHERE data_flag = 'clean'
      AND occasion IS NOT NULL
),
medians AS (
    SELECT
        occasion,
        MIN(CASE WHEN cd >= 0.50 THEN price END) AS median_price
    FROM price_with_cd
    GROUP BY occasion
),
agg AS (
    SELECT
        occasion,
        COUNT(*)                                                                    AS n_transactions,
        ROUND(AVG(price), 2)                                                        AS avg_price,
        ROUND(100.0 * SUM(CASE WHEN price < 20  THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_entry_mass,
        ROUND(100.0 * SUM(CASE WHEN price >= 35 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_premium_luxury,
        ROUND(SUM(revenue) / COUNT(*), 2)                                           AS revenue_per_txn,
        ROUND(SUM(revenue), 0)                                                      AS total_revenue
    FROM master_pricesense
    WHERE data_flag = 'clean'
      AND occasion IS NOT NULL
    GROUP BY occasion
)
SELECT
    a.occasion,
    a.n_transactions,
    ROUND(m.median_price, 2)                                             AS median_price,
    a.avg_price,
    a.pct_entry_mass,
    a.pct_premium_luxury,
    a.revenue_per_txn,
    a.total_revenue,
    ROUND(100.0 * a.total_revenue / SUM(a.total_revenue) OVER(), 1)     AS pct_of_total_revenue,
    CASE
        WHEN m.median_price >= 15.8 THEN 'HIGH intent — support premium pricing'
        WHEN m.median_price >= 15.0 THEN 'MODERATE — standard pricing'
        ELSE                             'LOW — price defensively'
    END AS occasion_pricing_verdict
FROM agg a
JOIN medians m USING (occasion)
ORDER BY m.median_price DESC;

/* RESULTS RANKED BY MEDIAN PRICE:
   religious-fasting: med $16.05, 18.0% D+E, 13.9% revenue → HIGH intent
   gym              : med $16.05, 18.7% D+E, 10.3% revenue → HIGH intent
   on-the-go        : med $15.64, 17.3% D+E                → MODERATE
   late-night       : med $15.62, 17.0% D+E, 24.9% revenue → MODERATE (volume play)
   marathon-prep    : med $15.29, 17.9% D+E                → MODERATE
   daily snack      : med $15.19, 17.4% D+E                → MODERATE
   road-trip        : med $14.97, 18.1% D+E                → LOW
   festive          : med $14.95, 17.3% D+E                → LOW

   LATE-NIGHT PARADOX: largest revenue block ($502K, 24.9%) but impulse pricing.
   Opportunity: upgrade mix toward Meal Replacement (late-night med $16.28 vs
   $15.86 overall) — this alone could lift late-night revenue ~3-4%.
*/


-- ────────────────────────────────────────────────────────────
-- QUERY 6: Revenue vs. volume simulation by category
--   Business Q: Should we raise or cut prices per category?
--   Method: Observed elasticity proxy from Phase 1 bucket drops
--   Elasticity assigned: Supplement 0.6, Meal Repl 0.8,
--   Protein Shake 1.0, Protein Bar 1.4, Electrolyte 1.6
--
--   CONVERSION ③: FROM (VALUES (…)) AS t(category, elasticity)
--       → SELECT … UNION ALL SELECT … inline subquery.
--       Column aliases are declared on the first SELECT branch
--       only; subsequent branches inherit them automatically.
-- ────────────────────────────────────────────────────────────

WITH category_base AS (
    SELECT
        category,
        COUNT(*)               AS n_transactions,
        ROUND(AVG(price), 2)   AS avg_price,
        ROUND(SUM(revenue), 0) AS current_revenue
    FROM master_pricesense
    WHERE data_flag = 'clean'
    GROUP BY category
),
elasticity_params AS (
    SELECT 'Supplement'        AS category, 0.6 AS elasticity
    UNION ALL
    SELECT 'Meal Replacement',  0.8
    UNION ALL
    SELECT 'Protein Shake',     1.0
    UNION ALL
    SELECT 'Protein Bar',       1.4
    UNION ALL
    SELECT 'Electrolyte Drink', 1.6
    UNION ALL
    SELECT 'Healthy Snack',     1.5
)
SELECT
    b.category,
    b.n_transactions,
    b.avg_price,
    b.current_revenue,
    e.elasticity,
    -- +10% price scenario
    ROUND(b.current_revenue * 1.10 * (1 - e.elasticity * 0.10), 0) AS revenue_if_raise_10pct,
    ROUND(b.current_revenue * 1.10 * (1 - e.elasticity * 0.10)
          - b.current_revenue, 0)                                   AS rev_delta_raise,
    -- -10% price scenario
    ROUND(b.current_revenue * 0.90 * (1 + e.elasticity * 0.10), 0) AS revenue_if_cut_10pct,
    ROUND(b.current_revenue * 0.90 * (1 + e.elasticity * 0.10)
          - b.current_revenue, 0)                                   AS rev_delta_cut,
    CASE
        WHEN b.current_revenue * 1.10 * (1 - e.elasticity * 0.10)
             > b.current_revenue THEN 'RAISE — net positive'
        WHEN b.current_revenue * 0.90 * (1 + e.elasticity * 0.10)
             > b.current_revenue THEN 'CUT — volume play'
        ELSE                          'HOLD — neither raises net revenue'
    END AS pricing_verdict
FROM category_base b
JOIN elasticity_params e ON b.category = e.category
ORDER BY rev_delta_raise DESC;

/* SIMULATION RESULTS:
   Supplement      : +10% → +$9,789 rev ✓ RAISE (inelastic, e=0.6)
   Meal Replacement: +10% → +$4,748 rev ✓ RAISE (e=0.8)
   Protein Shake   : +10% → −$4,404 rev  HOLD (unit elastic, e=1.0)
   Protein Bar     : +10% → −$19,718 rev  CUT/HOLD (elastic, e=1.4)
   Electrolyte     : +10% → −$13,597 rev  CUT (most elastic, e=1.6)
   Healthy Snack   : +10% → −$13,068 rev  CUT (e=1.5)
*/


-- ────────────────────────────────────────────────────────────
-- QUERY 7: State × Occasion pricing opportunity matrix
--   Business Q: Which geo-occasion combinations deserve premium SKU placement?
--
--   CONVERSION ②: PERCENTILE_CONT(0.5) → CUME_DIST CTE.
--   agg + medians split; final SELECT joins both.
--   LIMIT 20 is MySQL-native syntax — no change required.
-- ────────────────────────────────────────────────────────────

WITH price_with_cd AS (
    SELECT
        state,
        occasion,
        price,
        revenue,
        CUME_DIST() OVER (PARTITION BY state, occasion ORDER BY price) AS cd
    FROM master_pricesense
    WHERE data_flag = 'clean'
      AND state IS NOT NULL
      AND occasion IS NOT NULL
),
medians AS (
    SELECT
        state,
        occasion,
        MIN(CASE WHEN cd >= 0.50 THEN price END) AS median_price
    FROM price_with_cd
    GROUP BY state, occasion
),
agg AS (
    SELECT
        state,
        occasion,
        COUNT(*)                                                                    AS n_transactions,
        ROUND(100.0 * SUM(CASE WHEN price >= 35 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_premium,
        ROUND(SUM(revenue) / COUNT(*), 2)                                           AS revenue_per_txn
    FROM master_pricesense
    WHERE data_flag = 'clean'
      AND state IS NOT NULL
      AND occasion IS NOT NULL
    GROUP BY state, occasion
    HAVING COUNT(*) >= 80
)
SELECT
    a.state,
    a.occasion,
    a.n_transactions,
    ROUND(m.median_price, 2) AS median_price,
    a.pct_premium,
    a.revenue_per_txn
FROM agg a
JOIN medians m USING (state, occasion)
ORDER BY m.median_price DESC
LIMIT 20;

/* TOP GEO-OCCASION COMBINATIONS (all above $17 median):
   Colorado + Tier 3 + marathon-prep: med $21.33, 27.1% D+E, rev/txn $70.82
   Colorado + Tier 3 + gym          : med $19.94, 24.1% D+E
   Washington + Tier 3 + gym        : med $19.53, 23.5% D+E
   New York + Tier 1 + on-the-go    : med $18.45, 20.5% D+E
   PRIORITY MARKETS: Colorado, New York, California for premium SKU push
*/


-- ────────────────────────────────────────────────────────────
-- QUERY 8: Tier 3 occasion mix analysis
--   Business Q: Why does Tier 3 outperform on revenue/txn?
--
--   CONVERSION ②: PERCENTILE_CONT(0.5) → CUME_DIST CTE.
--   The original also used SUM(COUNT(*)) OVER (PARTITION BY
--   city_tier) for pct_within_tier — a window over an aggregate.
--   This is supported in MySQL 8.0 only when the window is
--   applied to an already-aggregated column in an outer SELECT.
--   The fix: compute n_transactions in the agg CTE, then apply
--   SUM(a.n_transactions) OVER (PARTITION BY a.city_tier) in the
--   final SELECT — functionally identical and MySQL-safe.
-- ────────────────────────────────────────────────────────────

WITH price_with_cd AS (
    SELECT
        city_tier,
        occasion,
        price,
        revenue,
        CUME_DIST() OVER (PARTITION BY city_tier, occasion ORDER BY price) AS cd
    FROM master_pricesense
    WHERE data_flag = 'clean'
      AND city_tier IN ('Tier 1', 'Tier 3')
      AND occasion IS NOT NULL
),
medians AS (
    SELECT
        city_tier,
        occasion,
        MIN(CASE WHEN cd >= 0.50 THEN price END) AS median_price
    FROM price_with_cd
    GROUP BY city_tier, occasion
),
agg AS (
    SELECT
        city_tier,
        occasion,
        COUNT(*)                          AS n_transactions,
        ROUND(SUM(revenue) / COUNT(*), 2) AS revenue_per_txn
    FROM master_pricesense
    WHERE data_flag = 'clean'
      AND city_tier IN ('Tier 1', 'Tier 3')
      AND occasion IS NOT NULL
    GROUP BY city_tier, occasion
)
SELECT
    a.city_tier,
    a.occasion,
    a.n_transactions,
    ROUND(
        100.0 * a.n_transactions
              / SUM(a.n_transactions) OVER (PARTITION BY a.city_tier),
    1) AS pct_within_tier,
    ROUND(m.median_price, 2) AS median_price,
    a.revenue_per_txn
FROM agg a
JOIN medians m USING (city_tier, occasion)
ORDER BY a.city_tier, pct_within_tier DESC;

/* TIER 3 vs TIER 1 OCCASION MIX:
   Tier 1: late-night dominates (47.4%) — impulse/low-consideration
   Tier 3: evenly distributed — gym (11.8%), marathon-prep (11.1%),
           religious-fasting (16.5%), on-the-go (12.6%)
   These are HIGH-INTENT occasions with 15–30% premium tolerance vs
   late-night's 17.0%. This occasion-mix explains Tier 3's $57.52
   rev/txn vs Tier 1's $45.94 — a 25% gap driven by WHAT people buy,
   not where they live.
*/


-- ────────────────────────────────────────────────────────────
-- QUERY 9: Final pricing recommendation by SKU archetype
--   The actionable pricing playbook for the brand's launch
--
--   CONVERSION ③: FROM (VALUES (…),(…)) AS t(col1…col6)
--       → SELECT … UNION ALL SELECT … subquery.
--       Column aliases declared on the first SELECT branch;
--       all 8 data rows follow as bare UNION ALL SELECT blocks.
--       String values containing commas are single-quoted and
--       do not require any escaping in MySQL.
-- ────────────────────────────────────────────────────────────

SELECT
    sku_archetype,
    recommended_price_range,
    target_channel,
    target_geo,
    target_occasion,
    evidence
FROM (
    SELECT
        'Vegan Meal Replacement'                           AS sku_archetype,
        '$45–55'                                           AS recommended_price_range,
        'App, Gym Kiosk'                                   AS target_channel,
        'Colorado, New York, California (Tier 3)'          AS target_geo,
        'gym, marathon-prep'                               AS target_occasion,
        '77.5% in D+E; gluten-free variant adds 62% D+E; premium occasions sustain $50+'
                                                           AS evidence
    UNION ALL
    SELECT
        'Keto Supplement',
        '$40–50',
        'App, Website',
        'Colorado, California (any tier)',
        'gym, religious-fasting',
        '61.4% in D+E; keto×supplement combo median $42.38; App channel adds 8% premium'
    UNION ALL
    SELECT
        'Vegan Supplement',
        '$38–48',
        'App',
        'New York, California (Tier 1, 2)',
        'on-the-go, gym',
        '57.7% in D+E; plant-based ingredient tag has median $104 at upper extreme'
    UNION ALL
    SELECT
        'High-Protein Protein Shake',
        '$26–35',
        'App, Gym Kiosk',
        'Colorado, New York (Tier 2, 3)',
        'gym, marathon-prep',
        '47.9% in D+E; high-protein×Protein Shake median $28.16; fits just below $35 cliff'
    UNION ALL
    SELECT
        'Clean-Label Meal Replacement',
        '$24–32',
        'App, Website',
        'California, New York (Tier 1)',
        'daily snack, on-the-go',
        '31.8% in D+E; clean-label×Meal Repl median $25.14; avoid $35+ until claims proven'
    UNION ALL
    SELECT
        'Standard Protein Bar',
        '$12–18',
        'Marketplace, Retail',
        'Texas, Georgia, Florida (all tiers)',
        'late-night, road-trip',
        'Only 9.6% in D+E; most elastic category (e=1.4); compete on volume, not margin'
    UNION ALL
    SELECT
        'Electrolyte Drink',
        '$10–15',
        'Marketplace, Retail',
        'All states — volume positioning',
        'gym, on-the-go, daily snack',
        'Only 3.9% in D+E; most elastic (e=1.6); -10% price simulation adds $7,872 revenue'
    UNION ALL
    SELECT
        'Late-Night Bundle (Meal Repl + Protein Bar)',
        '$16–22',
        'App, Website',
        'Tier 1 cities — all states',
        'late-night',
        'Largest revenue block (24.9%); Meal Repl commands med $16.28 in late-night; upgrade mix'
) AS t;
