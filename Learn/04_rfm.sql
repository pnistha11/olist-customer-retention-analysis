/* ============================================================
   DELIVERABLE 3 — RFM SEGMENTATION
   NTILE(5) quintiles on Recency / Frequency / Monetary,
   mapped to named segments, sized by customers and revenue.
   ============================================================ */

USE olist;

/* ------------------------------------------------------------
   READ THIS BEFORE YOU RUN IT — the frequency problem

   Textbook RFM assumes frequency actually varies. In Olist it
   barely does: ~97% of customers have exactly 1 order. Handing
   NTILE(5) a column that is almost entirely the value 1 does NOT
   produce meaningful quintiles — it slices the tied block at
   arbitrary points, so two identical customers land in different
   tiers purely by row order.

   So this script produces BOTH:
     - f_score_ntile : the literal NTILE version the brief asks for
     - f_score       : a rule-based score that respects the real
                       distribution (1 order = 1, 2 = 3, 3+ = 5)
   Segments are built on the rule-based score.

   Spotting this and saying so is a stronger signal than silently
   producing five tidy-looking frequency tiers that mean nothing.
   Recency and monetary DO vary, so NTILE is fine for both.
   ------------------------------------------------------------ */

WITH snapshot AS (
    -- "Today" = day after the last order in the dataset.
    SELECT DATE_ADD(DATE(MAX(order_purchase_timestamp)), INTERVAL 1 DAY) AS as_of
    FROM orders
),

order_value AS (
    -- Revenue = item price + freight, summed per order.
    -- Alternative: SUM(payment_value) from order_payments. That
    -- includes vouchers and installment quirks and won't tie out
    -- exactly. Pick one, state it, stay consistent.
    SELECT order_id, SUM(price + freight_value) AS order_revenue
    FROM order_items
    GROUP BY order_id
),

customer_base AS (
    SELECT
        c.customer_unique_id                        AS person,
        MAX(o.order_purchase_timestamp)             AS last_order_at,
        COUNT(DISTINCT o.order_id)                  AS frequency,
        COALESCE(SUM(v.order_revenue), 0)           AS monetary
    FROM orders o
    JOIN customers c   ON c.customer_id = o.customer_id
    LEFT JOIN order_value v ON v.order_id = o.order_id
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
      AND o.order_purchase_timestamp IS NOT NULL
    GROUP BY c.customer_unique_id
    HAVING monetary > 0
),

rfm_raw AS (
    SELECT
        b.person,
        DATEDIFF(s.as_of, DATE(b.last_order_at)) AS recency_days,
        b.frequency,
        ROUND(b.monetary, 2)                     AS monetary
    FROM customer_base b
    CROSS JOIN snapshot s
),

scored AS (
    SELECT
        person, recency_days, frequency, monetary,

        /* Recency: fewer days = better. Order DESC so the biggest
           recency_days lands in tile 1 and the freshest in tile 5.
           After this, 5 is always "good" for every dimension. */
        NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,

        /* The literal NTILE frequency score — kept for comparison */
        NTILE(5) OVER (ORDER BY frequency ASC)     AS f_score_ntile,

        /* The honest frequency score */
        CASE WHEN frequency >= 3 THEN 5
             WHEN frequency  = 2 THEN 3
             ELSE 1 END                            AS f_score,

        NTILE(5) OVER (ORDER BY monetary ASC)      AS m_score
    FROM rfm_raw
),

segmented AS (
    SELECT
        s.*,
        CONCAT(r_score, f_score, m_score) AS rfm_cell,
        CASE
            WHEN r_score >= 4 AND f_score >= 4 THEN 'Champions'
            WHEN r_score <= 2 AND f_score >= 5 THEN 'Cannot Lose Them'
            WHEN r_score >= 3 AND f_score >= 3 THEN 'Loyal Customers'
            WHEN r_score <= 2 AND f_score >= 3 THEN 'At Risk'
            WHEN r_score  = 5 AND f_score <= 2 THEN 'New Customers'
            WHEN r_score  = 4 AND f_score <= 2 THEN 'Promising'
            WHEN r_score  = 3 AND f_score <= 2 THEN 'Needs Attention'
            WHEN r_score <= 2 AND f_score <= 2 THEN 'Hibernating'
            ELSE 'Others'
        END AS segment
    FROM scored s
)

/* ---------- MAIN OUTPUT: segment sizes and revenue share ---------- */
SELECT
    segment,
    COUNT(*)                                                    AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)          AS pct_customers,
    ROUND(SUM(monetary), 2)                                     AS revenue_brl,
    ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 2) AS pct_revenue,
    ROUND(AVG(monetary), 2)                                     AS avg_value_brl,
    ROUND(AVG(recency_days))                                    AS avg_recency_days,
    ROUND(AVG(frequency), 2)                                    AS avg_frequency
FROM segmented
GROUP BY segment
ORDER BY revenue_brl DESC;

/* The gap between pct_customers and pct_revenue is your memo's
   money line: "X% of customers generate Y% of revenue."
   If Hibernating turns out to be both the largest segment AND a
   large revenue share, that is a reactivation case with numbers
   attached — exactly what a category manager can act on. */


/* ============================================================
   SAVE THE RESULTS so Python/Tableau can read them without
   re-running the CTE chain every time.
   ============================================================ */

DROP TABLE IF EXISTS rfm_customers;
CREATE TABLE rfm_customers AS
WITH snapshot AS (
    SELECT DATE_ADD(DATE(MAX(order_purchase_timestamp)), INTERVAL 1 DAY) AS as_of
    FROM orders
),
order_value AS (
    SELECT order_id, SUM(price + freight_value) AS order_revenue
    FROM order_items GROUP BY order_id
),
customer_base AS (
    SELECT c.customer_unique_id AS person,
           MAX(o.order_purchase_timestamp) AS last_order_at,
           COUNT(DISTINCT o.order_id)      AS frequency,
           COALESCE(SUM(v.order_revenue),0) AS monetary
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    LEFT JOIN order_value v ON v.order_id = o.order_id
    WHERE o.order_status NOT IN ('canceled','unavailable')
      AND o.order_purchase_timestamp IS NOT NULL
    GROUP BY c.customer_unique_id
    HAVING monetary > 0
),
rfm_raw AS (
    SELECT b.person,
           DATEDIFF(s.as_of, DATE(b.last_order_at)) AS recency_days,
           b.frequency,
           ROUND(b.monetary,2) AS monetary
    FROM customer_base b CROSS JOIN snapshot s
),
scored AS (
    SELECT person, recency_days, frequency, monetary,
           NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
           NTILE(5) OVER (ORDER BY frequency ASC)     AS f_score_ntile,
           CASE WHEN frequency >= 3 THEN 5
                WHEN frequency  = 2 THEN 3
                ELSE 1 END                            AS f_score,
           NTILE(5) OVER (ORDER BY monetary ASC)      AS m_score
    FROM rfm_raw
)
SELECT s.*,
       CONCAT(r_score, f_score, m_score) AS rfm_cell,
       CASE
           WHEN r_score >= 4 AND f_score >= 4 THEN 'Champions'
           WHEN r_score <= 2 AND f_score >= 5 THEN 'Cannot Lose Them'
           WHEN r_score >= 3 AND f_score >= 3 THEN 'Loyal Customers'
           WHEN r_score <= 2 AND f_score >= 3 THEN 'At Risk'
           WHEN r_score  = 5 AND f_score <= 2 THEN 'New Customers'
           WHEN r_score  = 4 AND f_score <= 2 THEN 'Promising'
           WHEN r_score  = 3 AND f_score <= 2 THEN 'Needs Attention'
           WHEN r_score <= 2 AND f_score <= 2 THEN 'Hibernating'
           ELSE 'Others'
       END AS segment
FROM scored s;

CREATE INDEX ix_rfm_segment ON rfm_customers (segment);


/* ------------------------------------------------------------
   SUPPORTING CUTS
   ------------------------------------------------------------ */

-- Sanity check: does the NTILE frequency score actually separate
-- anyone? Run this and look at the frequency range inside each tile.
SELECT f_score_ntile,
       COUNT(*)       AS customers,
       MIN(frequency) AS min_freq,
       MAX(frequency) AS max_freq
FROM rfm_customers
GROUP BY f_score_ntile
ORDER BY f_score_ntile;
-- Tiles 1-4 will all be min=1, max=1. That is the tie problem,
-- visible in one screenshot. Put this in your write-up.


-- Pareto check: what share of revenue comes from the top 20%?
WITH ranked AS (
    SELECT monetary,
           NTILE(5) OVER (ORDER BY monetary DESC) AS value_quintile
    FROM rfm_customers
)
SELECT value_quintile,
       COUNT(*) AS customers,
       ROUND(SUM(monetary), 2) AS revenue_brl,
       ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 2) AS pct_revenue
FROM ranked
GROUP BY value_quintile
ORDER BY value_quintile;


-- Which categories do the highest-value customers buy first?
-- (Acquisition lever: recruit more people into the good cohort.)
SELECT COALESCE(t.product_category_name_english, p.product_category_name) AS category,
       COUNT(DISTINCT rc.person) AS high_value_customers,
       ROUND(AVG(rc.monetary), 2) AS avg_customer_value_brl
FROM rfm_customers rc
JOIN customers c   ON c.customer_unique_id = rc.person
JOIN orders o      ON o.customer_id = c.customer_id
JOIN order_items i ON i.order_id = o.order_id
JOIN products p    ON p.product_id = i.product_id
LEFT JOIN category_translation t
       ON t.product_category_name = p.product_category_name
WHERE rc.m_score = 5
GROUP BY category
HAVING high_value_customers >= 100
ORDER BY high_value_customers DESC
LIMIT 15;


/* ------------------------------------------------------------
   YOUR TURN
   - Re-run the segment table using f_score_ntile instead of
     f_score. Compare. Explain in two sentences why the numbers
     move and which version you'd show a stakeholder.
   - Add a T dimension (tenure: days since FIRST order) to tell
     "genuinely new" apart from "bought once two years ago".
   - Compute average review_score per segment. Do At Risk
     customers have measurably worse experiences? If yes, your
     retention problem is really a service problem.
   ------------------------------------------------------------ */
