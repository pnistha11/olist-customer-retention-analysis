/* ============================================================
   FUNNEL EXTENSIONS — the three "your turn" exercises

   All three reuse timestamps already in the orders table.
   No new joins except reviews and customers.
   ============================================================ */

USE olist;


/* ============================================================
   EXERCISE 1 — MEDIAN DELIVERY TIME BY STATE

   Question: how much slower is the north than São Paulo?

   If the spread is large, "customers don't come back" is partly
   "customers in some states wait three weeks for a parcel", and
   the fix is a distribution centre or carrier change, not an
   email campaign.

   MySQL has no MEDIAN(), so the ROW_NUMBER + middle-value
   pattern comes back. Note the PARTITION BY state this time:
   we need a separate median for each state, not one overall.
   ============================================================ */

WITH delivered AS (
    SELECT
        c.customer_state AS state,
        TIMESTAMPDIFF(DAY, o.order_purchase_timestamp,
                           o.order_delivered_customer_date) AS days_to_deliver,
        /* Late = arrived after the date the customer was promised.
           Boolean, so SUM() counts them. */
        (o.order_delivered_customer_date > o.order_estimated_delivery_date) AS was_late
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_delivered_customer_date IS NOT NULL
      AND o.order_purchase_timestamp IS NOT NULL
      AND o.order_status NOT IN ('canceled','unavailable')
),
ranked AS (
    SELECT state, days_to_deliver, was_late,
           ROW_NUMBER() OVER (PARTITION BY state ORDER BY days_to_deliver) AS rn,
           COUNT(*)     OVER (PARTITION BY state)                          AS n
    FROM delivered
    WHERE days_to_deliver >= 0    -- a few rows have inverted timestamps
)
SELECT
    state,
    MAX(n)                                                       AS orders,
    /* median: middle row (odd n) or average of middle two (even n) */
    ROUND(AVG(CASE WHEN rn IN (FLOOR((n+1)/2), CEIL((n+1)/2))
                   THEN days_to_deliver END), 1)                 AS median_days,
    /* p90: the slow tail, where the angry customers are */
    MAX(CASE WHEN rn = CEIL(0.90 * n) THEN days_to_deliver END)  AS p90_days,
    ROUND(AVG(days_to_deliver), 1)                               AS mean_days,
    ROUND(100.0 * SUM(was_late) / COUNT(*), 2)                   AS pct_late
FROM ranked
GROUP BY state
HAVING orders >= 200          -- drop tiny states; their medians are noise
ORDER BY median_days DESC;

/* Read the top and bottom rows together. The gap between the
   slowest state and SP is your headline. Pair it with the
   share of orders in each: if the slow states are only 3% of
   volume, the fix is cheap; if they're 20%, it's urgent. */


/* ============================================================
   EXERCISE 2 — FUNNEL BY MONTH

   Question: is drop-off getting better or worse?

   A static funnel says where you lose orders. A funnel over
   time says whether anyone is fixing it. That difference
   turns an observation into a trend.

   Grouping is by the month the order was PLACED, so each
   order stays in one cohort regardless of when it delivered.
   ============================================================ */

WITH base AS (
    SELECT
        CAST(DATE_FORMAT(o.order_purchase_timestamp,'%Y-%m-01') AS DATE) AS month,
        o.order_approved_at             AS t_approved,
        o.order_delivered_carrier_date  AS t_shipped,
        o.order_delivered_customer_date AS t_delivered,
        TIMESTAMPDIFF(DAY, o.order_purchase_timestamp,
                           o.order_delivered_customer_date) AS days_to_deliver
    FROM orders o
    WHERE o.order_purchase_timestamp IS NOT NULL
)
SELECT
    month,
    COUNT(*)                                                     AS placed,
    /* Same forced nesting as the main funnel: you can't be
       delivered without having been approved and shipped. */
    ROUND(100.0 * SUM(t_approved IS NOT NULL) / COUNT(*), 2)     AS pct_approved,
    ROUND(100.0 * SUM(t_approved IS NOT NULL
                      AND t_shipped IS NOT NULL) / COUNT(*), 2)  AS pct_shipped,
    ROUND(100.0 * SUM(t_approved IS NOT NULL
                      AND t_shipped IS NOT NULL
                      AND t_delivered IS NOT NULL) / COUNT(*), 2) AS pct_delivered,
    ROUND(AVG(days_to_deliver), 1)                               AS avg_days_to_deliver
FROM base
WHERE month BETWEEN '2017-01-01' AND '2018-08-01'
GROUP BY month
ORDER BY month;

/* CAREFUL READING THE LAST MONTHS: an order placed in August
   2018 may still have been in transit when the data was
   extracted, so pct_delivered dips at the right edge. That is
   truncation, not a real collapse in fulfilment — the same
   censoring trap as the cohort chart. Say so if you use this. */


/* ============================================================
   EXERCISE 3 — HOW MANY STARS DOES LATENESS COST?

   Question: quantify the relationship between delivery delay
   and review score.

   This is the query that connects operations to customer
   sentiment. If each extra day late costs measurable stars,
   the delivery problem has a number attached to it.
   ============================================================ */

WITH order_review AS (
    -- one score per order (an order can have several review rows)
    SELECT order_id, AVG(review_score) AS order_score
    FROM order_reviews
    WHERE review_score IS NOT NULL
    GROUP BY order_id
),
lateness AS (
    SELECT
        r.order_score,
        /* Negative = arrived early, positive = arrived late.
           Measuring against the PROMISED date, not raw transit
           time, because customers judge against expectation. */
        DATEDIFF(o.order_delivered_customer_date,
                 o.order_estimated_delivery_date) AS days_late
    FROM orders o
    JOIN order_review r ON r.order_id = o.order_id
    WHERE o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
      AND o.order_status NOT IN ('canceled','unavailable')
)
SELECT
    CASE
        WHEN days_late <  -7 THEN '1. more than a week early'
        WHEN days_late <   0 THEN '2. early'
        WHEN days_late =   0 THEN '3. on the promised day'
        WHEN days_late <=  3 THEN '4. 1-3 days late'
        WHEN days_late <=  7 THEN '5. 4-7 days late'
        WHEN days_late <= 14 THEN '6. 1-2 weeks late'
        ELSE                      '7. more than 2 weeks late'
    END                                                  AS delivery_vs_promise,
    COUNT(*)                                             AS orders,
    ROUND(AVG(order_score), 2)                           AS avg_review_score,
    ROUND(100.0 * SUM(order_score <= 2) / COUNT(*), 1)   AS pct_1_or_2_star,
    ROUND(100.0 * SUM(order_score >= 5) / COUNT(*), 1)   AS pct_5_star
FROM lateness
GROUP BY delivery_vs_promise
ORDER BY delivery_vs_promise;


-- The single number version: stars lost per day late.
-- A crude linear slope, but it fits in one sentence of a memo.
WITH order_review AS (
    SELECT order_id, AVG(review_score) AS order_score
    FROM order_reviews WHERE review_score IS NOT NULL GROUP BY order_id
),
lateness AS (
    SELECT r.order_score AS y,
           DATEDIFF(o.order_delivered_customer_date,
                    o.order_estimated_delivery_date) AS x
    FROM orders o
    JOIN order_review r ON r.order_id = o.order_id
    WHERE o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
      AND o.order_status NOT IN ('canceled','unavailable')
)
SELECT
    COUNT(*) AS orders,
    /* Least-squares slope, written out longhand:
       slope = (n*Sxy - Sx*Sy) / (n*Sxx - Sx^2)          */
    ROUND(
      (COUNT(*) * SUM(x*y) - SUM(x) * SUM(y)) /
      (COUNT(*) * SUM(x*x) - SUM(x) * SUM(x))
    , 4) AS stars_per_day_late,
    ROUND(AVG(y), 3) AS mean_score
FROM lateness
WHERE x BETWEEN -30 AND 60;   -- trim extreme outliers

/* Interpreting the slope: a value of -0.05 means each extra day
   past the promised date costs about 0.05 stars on average.
   Multiply by a typical delay to get the real-world effect.

   HONEST CAVEAT for the memo: this is correlation. Late orders
   may also be the ones with damaged goods or bad sellers, so
   lateness isn't necessarily the sole cause. Say that — it
   costs you nothing and buys credibility. */
