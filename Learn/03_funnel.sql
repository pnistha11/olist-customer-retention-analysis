/* ============================================================
   DELIVERABLE 2 — ORDER FUNNEL WITH DROP-OFF
   placed -> approved -> shipped -> delivered -> reviewed
   Conversion rate + median time at each stage.
   ============================================================ */

USE olist;

/* ------------------------------------------------------------
   TWO DESIGN DECISIONS WORTH EXPLAINING OUT LOUD

   1. Stages come from TIMESTAMPS, not order_status.
      order_status is a current-state snapshot — a delivered order
      says 'delivered', erasing the fact that it was once approved.
      The timestamp columns preserve the whole history.

   2. The funnel is FORCED to nest.
      Olist emails the review survey when an order SHIPS, not when
      it arrives. So raw review counts exceed delivered counts and
      you get a "conversion rate" above 100%, which is nonsense in
      a funnel. Below, each stage requires every prior stage.
      Query at the bottom shows the unforced version so you can
      quantify the anomaly and mention it in the memo.
   ------------------------------------------------------------ */

WITH base AS (
    SELECT
        o.order_id,
        o.order_purchase_timestamp      AS t_placed,
        o.order_approved_at             AS t_approved,
        o.order_delivered_carrier_date  AS t_shipped,
        o.order_delivered_customer_date AS t_delivered,
        r.t_reviewed
    FROM orders o
    LEFT JOIN (
        -- an order can have several review rows; keep the earliest
        SELECT order_id, MIN(review_creation_date) AS t_reviewed
        FROM order_reviews
        WHERE review_creation_date IS NOT NULL
        GROUP BY order_id
    ) r ON r.order_id = o.order_id
    WHERE o.order_purchase_timestamp IS NOT NULL
),

/* Force monotonic nesting: you can't reach stage N without N-1. */
nested AS (
    SELECT
        order_id,
        1                                                       AS s_placed,
        (t_approved IS NOT NULL)                                AS s_approved,
        (t_approved IS NOT NULL AND t_shipped IS NOT NULL)      AS s_shipped,
        (t_approved IS NOT NULL AND t_shipped IS NOT NULL
         AND t_delivered IS NOT NULL)                           AS s_delivered,
        (t_approved IS NOT NULL AND t_shipped IS NOT NULL
         AND t_delivered IS NOT NULL AND t_reviewed IS NOT NULL) AS s_reviewed
    FROM base
),

funnel AS (
    SELECT 1 AS step_no, '1. Placed'    AS stage, SUM(s_placed)    AS orders FROM nested
    UNION ALL
    SELECT 2, '2. Approved',  SUM(s_approved)  FROM nested
    UNION ALL
    SELECT 3, '3. Shipped',   SUM(s_shipped)   FROM nested
    UNION ALL
    SELECT 4, '4. Delivered', SUM(s_delivered) FROM nested
    UNION ALL
    SELECT 5, '5. Reviewed',  SUM(s_reviewed)  FROM nested
)

SELECT
    stage,
    orders,
    /* survival from the top of the funnel */
    ROUND(100.0 * orders / FIRST_VALUE(orders) OVER (ORDER BY step_no), 2)
        AS pct_of_placed,
    /* conversion from the immediately preceding stage */
    ROUND(100.0 * orders / LAG(orders) OVER (ORDER BY step_no), 2)
        AS step_conversion_pct,
    /* absolute bodies lost at this step — this is what a category
       manager actually reacts to */
    LAG(orders) OVER (ORDER BY step_no) - orders
        AS dropped_here
FROM funnel
ORDER BY step_no;


/* ============================================================
   MEDIAN TIME AT EACH STAGE

   MySQL 8 has no MEDIAN() / PERCENTILE_CONT(). The standard
   workaround: rank the rows, then average the middle one (odd n)
   or middle two (even n). Learn this pattern — it comes up
   constantly in MySQL interviews.

   We measure in MINUTES then convert, because TIMESTAMPDIFF(HOUR)
   truncates and would report a 59-minute approval as 0 hours.

   We also drop negative durations. A few rows have timestamps out
   of order (approved before purchase). Real data does this.
   ============================================================ */

WITH base AS (
    SELECT
        o.order_id,
        o.order_purchase_timestamp      AS t_placed,
        o.order_approved_at             AS t_approved,
        o.order_delivered_carrier_date  AS t_shipped,
        o.order_delivered_customer_date AS t_delivered,
        r.t_reviewed
    FROM orders o
    LEFT JOIN (
        SELECT order_id, MIN(review_creation_date) AS t_reviewed
        FROM order_reviews
        WHERE review_creation_date IS NOT NULL
        GROUP BY order_id
    ) r ON r.order_id = o.order_id
    WHERE o.order_purchase_timestamp IS NOT NULL
),

/* Unpivot each order into one row per completed transition. */
durations AS (
    SELECT 1 AS step_no, 'placed -> approved'    AS transition,
           TIMESTAMPDIFF(MINUTE, t_placed, t_approved) AS mins
    FROM base WHERE t_approved IS NOT NULL
    UNION ALL
    SELECT 2, 'approved -> shipped',
           TIMESTAMPDIFF(MINUTE, t_approved, t_shipped)
    FROM base WHERE t_approved IS NOT NULL AND t_shipped IS NOT NULL
    UNION ALL
    SELECT 3, 'shipped -> delivered',
           TIMESTAMPDIFF(MINUTE, t_shipped, t_delivered)
    FROM base WHERE t_shipped IS NOT NULL AND t_delivered IS NOT NULL
    UNION ALL
    SELECT 4, 'delivered -> reviewed',
           TIMESTAMPDIFF(MINUTE, t_delivered, t_reviewed)
    FROM base WHERE t_delivered IS NOT NULL AND t_reviewed IS NOT NULL
    UNION ALL
    SELECT 5, 'placed -> delivered (end to end)',
           TIMESTAMPDIFF(MINUTE, t_placed, t_delivered)
    FROM base WHERE t_delivered IS NOT NULL
),

ranked AS (
    SELECT
        step_no, transition, mins,
        ROW_NUMBER() OVER (PARTITION BY step_no ORDER BY mins) AS rn,
        COUNT(*)     OVER (PARTITION BY step_no)               AS n
    FROM durations
    WHERE mins >= 0
)

SELECT
    transition,
    MAX(n)                                                        AS n_orders,
    ROUND(AVG(CASE WHEN rn IN (FLOOR((n+1)/2), CEIL((n+1)/2))
                   THEN mins END) / 60.0, 1)                      AS median_hours,
    ROUND(AVG(CASE WHEN rn IN (FLOOR((n+1)/2), CEIL((n+1)/2))
                   THEN mins END) / 1440.0, 2)                    AS median_days,
    ROUND(AVG(mins) / 1440.0, 2)                                  AS mean_days,
    /* p90 shows the tail — the customers who are actually angry */
    ROUND(MAX(CASE WHEN rn = CEIL(0.90 * n) THEN mins END) / 1440.0, 2)
                                                                  AS p90_days
FROM ranked
GROUP BY step_no, transition
ORDER BY step_no;

/* Reading the output: median approval is under a day, median
   end-to-end delivery lands around 10-11 days, but the p90 is
   roughly triple the median. Averages hide that; the p90 is the
   number worth putting in a memo. */


/* ------------------------------------------------------------
   THE ANOMALY — quantify it so you can mention it credibly
   ------------------------------------------------------------ */
SELECT
    SUM(o.order_delivered_customer_date IS NOT NULL)  AS delivered_orders,
    SUM(r.order_id IS NOT NULL)                       AS orders_with_review,
    SUM(r.order_id IS NOT NULL
        AND o.order_delivered_customer_date IS NULL)  AS reviewed_but_not_delivered
FROM orders o
LEFT JOIN (SELECT DISTINCT order_id FROM order_reviews) r
       ON r.order_id = o.order_id;
-- Thousands of orders are reviewed without ever being marked
-- delivered. Reviews fire on dispatch, so "reviewed" is not a
-- clean bottom-of-funnel event. Say this in one line in the memo.


/* ------------------------------------------------------------
   WHERE THE MONEY LEAKS — attach R$ to the drop-off
   ------------------------------------------------------------ */
SELECT
    o.order_status,
    COUNT(DISTINCT o.order_id)                     AS orders,
    ROUND(SUM(i.price + i.freight_value), 2)       AS gmv_brl,
    ROUND(100.0 * SUM(i.price + i.freight_value)
          / SUM(SUM(i.price + i.freight_value)) OVER (), 2) AS pct_gmv
FROM orders o
JOIN order_items i ON i.order_id = o.order_id
GROUP BY o.order_status
ORDER BY gmv_brl DESC;
-- The R$ sitting in canceled / unavailable / stuck-in-transit
-- statuses is your "why it matters" number.


/* ------------------------------------------------------------
   YOUR TURN
   - Split median delivery time by customer_state. The spread
     between SP and the northern states is dramatic and is a
     ready-made recommendation.
   - Cut the funnel by month to see whether drop-off is getting
     better or worse over time.
   - Join review_score onto delivery lateness: how many stars do
     you lose per extra day late?
   ------------------------------------------------------------ */
