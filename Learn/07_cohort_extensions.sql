/* ============================================================
   COHORT EXTENSIONS — the three "your turn" exercises

   All three reuse the same skeleton as 02_cohort_retention.sql.
   Read the comments; the changes are small and deliberate.

   TWO RULES CARRIED OVER FROM THE MAIN ANALYSIS:
   1. Cohorts are cut off at 2018-04 so every group gets the same
      3 months of observation. Comparing a group watched for 12
      months against one watched for 1 month is meaningless.
   2. The 2018-08 cohort is excluded everywhere — its numbers are
      dataset truncation, not customer behaviour.
   ============================================================ */

USE olist;


/* ============================================================
   EXERCISE 1 — DOES REPEAT RATE DIFFER BY STATE?

   Question: are customers in São Paulo (dense, close to sellers,
   fast delivery) more likely to come back than customers in the
   far north (sparse, long shipping distances)?

   If yes, retention is partly a logistics problem, not a
   marketing one. That changes what you recommend.
   ============================================================ */

WITH cust_orders AS (
    SELECT c.customer_unique_id       AS person,
           o.order_purchase_timestamp AS ts,
           c.customer_state           AS state
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled','unavailable')
      AND o.order_purchase_timestamp IS NOT NULL
),

/* NEW: FIRST_VALUE picks the state on the person's earliest order.
   Needed because customer_state lives on the per-order customer
   row, so someone who moved would have two different states. We
   want one label per person: where they were when we acquired
   them. FIRST_VALUE needs ORDER BY inside OVER() to know which
   row is "first" — MIN() didn't, because minimum has no order. */
stamped AS (
    SELECT person, ts,
           MIN(ts)          OVER (PARTITION BY person)              AS first_ts,
           FIRST_VALUE(state) OVER (PARTITION BY person ORDER BY ts) AS home_state
    FROM cust_orders
),

indexed AS (
    SELECT person, home_state,
           CAST(DATE_FORMAT(first_ts,'%Y-%m-01') AS DATE) AS cohort_month,
           TIMESTAMPDIFF(MONTH,
               CAST(DATE_FORMAT(first_ts,'%Y-%m-01') AS DATE),
               CAST(DATE_FORMAT(ts,'%Y-%m-01') AS DATE)) AS month_index
    FROM stamped
),

/* Fair-window filter. Everyone here gets exactly 3 months of
   observation, so states are comparable. */
eligible AS (
    SELECT * FROM indexed
    WHERE cohort_month BETWEEN '2017-01-01' AND '2018-04-01'
),

/* Collapse to one row per person: did they return in months 1-3?
   MAX(condition) returns 1 if the condition was true on ANY of
   that person's rows, 0 otherwise. It's "did this ever happen"
   written as an aggregate. */
per_person AS (
    SELECT person, home_state,
           MAX(month_index BETWEEN 1 AND 3) AS returned_in_90d
    FROM eligible
    GROUP BY person, home_state
)

SELECT home_state                                            AS state,
       COUNT(*)                                              AS customers,
       SUM(returned_in_90d)                                  AS repeaters,
       ROUND(100.0 * SUM(returned_in_90d) / COUNT(*), 2)     AS repeat_rate_pct
FROM per_person
GROUP BY home_state
/* HAVING filters AFTER grouping. Without it, a state with 12
   customers and 1 repeater shows an 8% rate and tops the chart
   on pure noise. 500 is a judgment call — state it. */
HAVING customers >= 500
ORDER BY repeat_rate_pct DESC;


/* ============================================================
   EXERCISE 2 — DOES THE FIRST PRODUCT PREDICT REPEAT?

   Question: some categories are naturally one-and-done (you buy
   one mattress). Others should repeat (cosmetics, pet supplies).
   Which categories repeat less than their nature suggests?

   That's an assortment recommendation: push acquisition toward
   categories that build habits.
   ============================================================ */

WITH ranked_orders AS (
    SELECT c.customer_unique_id       AS person,
           o.order_id,
           o.order_purchase_timestamp AS ts,
           ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id
                              ORDER BY o.order_purchase_timestamp) AS rn
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled','unavailable')
      AND o.order_purchase_timestamp IS NOT NULL
),

/* An order can contain several items in different categories.
   We take order_item_id = 1 as "the" category. Crude but
   defensible; alternative is the highest-priced item. Say which
   you chose. */
first_category AS (
    SELECT r.person,
           r.ts AS first_ts,
           COALESCE(t.product_category_name_english,
                    p.product_category_name,
                    'unknown')                                AS category
    FROM ranked_orders r
    JOIN order_items i ON i.order_id = r.order_id
                      AND i.order_item_id = 1
    JOIN products   p ON p.product_id = i.product_id
    /* LEFT JOIN because ~6 categories have no English translation.
       An inner join would silently delete those customers.
       COALESCE then falls back to the Portuguese name. */
    LEFT JOIN category_translation t
           ON t.product_category_name = p.product_category_name
    WHERE r.rn = 1
),

all_orders AS (
    SELECT c.customer_unique_id       AS person,
           o.order_purchase_timestamp AS ts
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled','unavailable')
      AND o.order_purchase_timestamp IS NOT NULL
),

flagged AS (
    SELECT fc.person,
           fc.category,
           MAX(TIMESTAMPDIFF(MONTH,
                 CAST(DATE_FORMAT(fc.first_ts,'%Y-%m-01') AS DATE),
                 CAST(DATE_FORMAT(a.ts,'%Y-%m-01') AS DATE))
               BETWEEN 1 AND 3)                               AS returned_in_90d
    FROM first_category fc
    JOIN all_orders a ON a.person = fc.person
    WHERE CAST(DATE_FORMAT(fc.first_ts,'%Y-%m-01') AS DATE)
          BETWEEN '2017-01-01' AND '2018-04-01'
    GROUP BY fc.person, fc.category
)

SELECT category,
       COUNT(*)                                              AS customers,
       SUM(returned_in_90d)                                  AS repeaters,
       ROUND(100.0 * SUM(returned_in_90d) / COUNT(*), 2)     AS repeat_rate_pct
FROM flagged
GROUP BY category
HAVING customers >= 500
ORDER BY repeat_rate_pct DESC;


/* ============================================================
   EXERCISE 3 — REVENUE RETENTION INSTEAD OF CUSTOMER RETENTION

   Same grid, different unit. Instead of "what % of people came
   back", this asks "what % of the cohort's first-month revenue
   did we earn again in month N".

   Why it matters: 100 customers spending R$50 and 100 spending
   R$500 look identical in a customer heatmap. In a revenue
   heatmap they don't. In healthy subscription businesses this
   can exceed 100% because survivors spend more. Here it won't —
   but knowing that the ceiling is different is the point.
   ============================================================ */

WITH order_value AS (
    SELECT order_id, SUM(price + freight_value) AS rev
    FROM order_items
    GROUP BY order_id
),

cust_orders AS (
    SELECT c.customer_unique_id       AS person,
           o.order_purchase_timestamp AS ts,
           COALESCE(v.rev, 0)         AS rev
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    LEFT JOIN order_value v ON v.order_id = o.order_id
    WHERE o.order_status NOT IN ('canceled','unavailable')
      AND o.order_purchase_timestamp IS NOT NULL
),

stamped AS (
    SELECT person, ts, rev,
           MIN(ts) OVER (PARTITION BY person) AS first_ts
    FROM cust_orders
),

indexed AS (
    SELECT rev,
           CAST(DATE_FORMAT(first_ts,'%Y-%m-01') AS DATE) AS cohort_month,
           TIMESTAMPDIFF(MONTH,
               CAST(DATE_FORMAT(first_ts,'%Y-%m-01') AS DATE),
               CAST(DATE_FORMAT(ts,'%Y-%m-01') AS DATE)) AS month_index
    FROM stamped
),

/* THE ONLY REAL CHANGE: SUM(rev) where the original had
   COUNT(DISTINCT person). Denominator and numerator both become
   money. No DISTINCT needed — two orders from one person are two
   real revenue events, unlike two orders from one person being
   still one customer. */
base_revenue AS (
    SELECT cohort_month, SUM(rev) AS month0_revenue
    FROM indexed
    WHERE month_index = 0
    GROUP BY cohort_month
),

cell_revenue AS (
    SELECT cohort_month, month_index, SUM(rev) AS cell_revenue
    FROM indexed
    GROUP BY cohort_month, month_index
)

SELECT c.cohort_month,
       ROUND(b.month0_revenue, 2)                              AS month0_revenue_brl,
       c.month_index,
       ROUND(c.cell_revenue, 2)                                AS cell_revenue_brl,
       ROUND(100.0 * c.cell_revenue / b.month0_revenue, 2)     AS pct_revenue_retained
FROM cell_revenue c
JOIN base_revenue b ON b.cohort_month = c.cohort_month
WHERE c.month_index BETWEEN 0 AND 12
  AND c.cohort_month BETWEEN '2017-01-01' AND '2018-07-01'
ORDER BY c.cohort_month, c.month_index;


/* ------------------------------------------------------------
   COMPARE THE TWO RETENTION MEASURES SIDE BY SIDE.
   If revenue retention is higher than customer retention, the
   few who return spend more than average — they're worth
   chasing. If it's lower, returners are bargain-hunters.
   Run exercise 3 and your original query, then compare month 1.
   ------------------------------------------------------------ */
