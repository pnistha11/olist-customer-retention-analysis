/* ============================================================
   DELIVERABLE 1 — MONTHLY RETENTION COHORTS
   Group customers by first-purchase month, measure the % who
   come back in months 1..12.

   THE ONE RULE: cohort on customer_unique_id, never customer_id.
   ============================================================ */

USE olist;

/* ------------------------------------------------------------
   Design decisions — be ready to defend these in an interview.

   Grain      : one row per (person, order).
   Population : all orders except 'canceled' and 'unavailable'.
                A cancelled order still shows purchase intent, but
                it never became revenue, so it shouldn't count as
                a "return". Reasonable people choose differently;
                what matters is that you state your choice.
   Window fn  : MIN(...) OVER (PARTITION BY person) instead of a
                GROUP BY subquery. Same answer, but it keeps the
                order-level rows alive so we can index them in
                one pass.
   Month index: TIMESTAMPDIFF on two first-of-month DATEs, so
                month_index is a clean integer. 0 = acquisition
                month, 1 = next calendar month, etc.
   ------------------------------------------------------------ */

WITH cust_orders AS (
    SELECT
        c.customer_unique_id            AS person,
        o.order_id,
        o.order_purchase_timestamp      AS ts
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
      AND o.order_purchase_timestamp IS NOT NULL
),

/* Window function does the work: stamp every order with that
   person's FIRST order time, without collapsing the rows. */
stamped AS (
    SELECT
        person,
        order_id,
        ts,
        MIN(ts) OVER (PARTITION BY person) AS first_ts
    FROM cust_orders
),

indexed AS (
    SELECT
        person,
        CAST(DATE_FORMAT(first_ts, '%Y-%m-01') AS DATE) AS cohort_month,
        CAST(DATE_FORMAT(ts,       '%Y-%m-01') AS DATE) AS activity_month,
        TIMESTAMPDIFF(
            MONTH,
            CAST(DATE_FORMAT(first_ts, '%Y-%m-01') AS DATE),
            CAST(DATE_FORMAT(ts,       '%Y-%m-01') AS DATE)
        ) AS month_index
    FROM stamped
),

/* Denominator: how many people entered each cohort. */
cohort_size AS (
    SELECT cohort_month, COUNT(DISTINCT person) AS n_customers
    FROM indexed
    WHERE month_index = 0
    GROUP BY cohort_month
),

/* Numerator: distinct people active in each (cohort, month_index). */
activity AS (
    SELECT cohort_month, month_index, COUNT(DISTINCT person) AS n_active
    FROM indexed
    GROUP BY cohort_month, month_index
),

/* The last month with data. Cells beyond this haven't happened
   yet — showing them as 0% is the classic cohort-chart lie. */
bounds AS (
    SELECT CAST(DATE_FORMAT(MAX(ts), '%Y-%m-01') AS DATE) AS last_month
    FROM cust_orders
)

SELECT
    a.cohort_month,
    s.n_customers                                   AS cohort_size,
    a.month_index,
    a.n_active                                      AS active_customers,
    ROUND(100.0 * a.n_active / s.n_customers, 2)    AS pct_retained,
    /* 1 = this cell had a real chance to happen; 0 = not yet observable */
    CASE WHEN DATE_ADD(a.cohort_month, INTERVAL a.month_index MONTH)
              <= b.last_month
         THEN 1 ELSE 0 END                          AS is_observable
FROM activity a
JOIN cohort_size s ON s.cohort_month = a.cohort_month
CROSS JOIN bounds b
WHERE a.month_index BETWEEN 0 AND 12
  /* Clip the noisy edges: 2016 has almost no orders, and the
     last month of data is partial. */
  AND a.cohort_month BETWEEN '2017-01-01' AND '2018-08-01'
ORDER BY a.cohort_month, a.month_index;


/* ============================================================
   WHAT YOU'RE ABOUT TO SEE — and why it isn't a bug

   Month 0 will be 100% by construction. Months 1-12 will mostly
   land between 0.0% and 0.5%. Some cells will be genuinely empty.

   That is correct. Olist is a marketplace where ~97% of customers
   never return. Your SQL is fine.

   The rookie move is to assume you broke something and start
   "fixing" it until the numbers look prettier. The professional
   move is to quantify it and ask what it costs the business.
   That framing is your memo.
   ============================================================ */


/* ------------------------------------------------------------
   SUPPORTING NUMBERS FOR THE MEMO
   ------------------------------------------------------------ */

-- 1) Headline repeat rate, one number.
SELECT
    COUNT(*)                                              AS total_customers,
    SUM(order_count > 1)                                  AS repeat_customers,
    ROUND(100.0 * SUM(order_count > 1) / COUNT(*), 2)     AS repeat_rate_pct
FROM (
    SELECT c.customer_unique_id, COUNT(DISTINCT o.order_id) AS order_count
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled','unavailable')
    GROUP BY c.customer_unique_id
) x;


-- 2) When repeat buyers DO come back, how long does it take?
--    (Feeds a "the window is short, act inside N days" recommendation.)
--    MySQL has no MEDIAN(), so we rank rows and take the middle.
WITH gaps AS (
    SELECT
        c.customer_unique_id AS person,
        TIMESTAMPDIFF(
            DAY,
            LAG(o.order_purchase_timestamp) OVER (
                PARTITION BY c.customer_unique_id
                ORDER BY o.order_purchase_timestamp),
            o.order_purchase_timestamp
        ) AS days_since_prev
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled','unavailable')
),
clean AS (
    SELECT days_since_prev AS d,
           ROW_NUMBER() OVER (ORDER BY days_since_prev) AS rn,
           COUNT(*)     OVER ()                          AS n
    FROM gaps
    WHERE days_since_prev IS NOT NULL
)
SELECT
    MAX(n)                                       AS repeat_purchase_events,
    ROUND(AVG(CASE WHEN rn IN (FLOOR((n+1)/2), CEIL((n+1)/2))
                   THEN d END), 1)               AS median_days_between,
    ROUND(AVG(d), 1)                             AS mean_days_between
FROM clean;


-- 3) Does a bad delivery experience kill the repeat purchase?
--    This is the kind of cut that turns a flat heatmap into a finding.
WITH first_order AS (
    SELECT
        c.customer_unique_id AS person,
        o.order_id,
        o.order_delivered_customer_date,
        o.order_estimated_delivery_date,
        ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id
                           ORDER BY o.order_purchase_timestamp) AS rn
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled','unavailable')
),
totals AS (
    SELECT c.customer_unique_id AS person, COUNT(DISTINCT o.order_id) AS n_orders
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled','unavailable')
    GROUP BY c.customer_unique_id
)
SELECT
    CASE
      WHEN f.order_delivered_customer_date IS NULL THEN 'never delivered'
      WHEN f.order_delivered_customer_date > f.order_estimated_delivery_date
           THEN 'late'
      ELSE 'on time'
    END                                                  AS first_delivery,
    COUNT(*)                                             AS customers,
    ROUND(100.0 * SUM(t.n_orders > 1) / COUNT(*), 2)     AS repeat_rate_pct
FROM first_order f
JOIN totals t ON t.person = f.person
WHERE f.rn = 1
GROUP BY first_delivery
ORDER BY repeat_rate_pct DESC;


/* ------------------------------------------------------------
   YOUR TURN (do at least one — this is where the learning is)
   - Rebuild the cohort by customer_state. Do repeat rates differ
     between São Paulo and the north?
   - Rebuild it by the product category of the FIRST order. Some
     categories are inherently one-off (furniture) and some should
     repeat (health_beauty). Which ones underperform their nature?
   - Swap "returned in month N" for "revenue in month N" to get a
     revenue-retention heatmap instead of a customer-count one.
   ------------------------------------------------------------ */
