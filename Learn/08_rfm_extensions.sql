/* ============================================================
   RFM EXTENSIONS — the three "your turn" exercises
   All three read from rfm_customers. Run 04_rfm.sql first.
   ============================================================ */

USE olist;


/* ============================================================
   EXERCISE 1 — NTILE vs RULE-BASED FREQUENCY SCORE

   Identical to the main segment table with one substitution:
   f_score_ntile replaces f_score everywhere in the CASE.
   Run the diagnostic first so you can see WHY the numbers move.
   ============================================================ */

-- Diagnostic: does NTILE actually separate anyone on frequency?
SELECT f_score_ntile,
       COUNT(*)       AS customers,
       MIN(frequency) AS min_freq,
       MAX(frequency) AS max_freq
FROM rfm_customers
GROUP BY f_score_ntile
ORDER BY f_score_ntile;
-- Expect tiles 1-4 to all show min=1, max=1: four "different"
-- tiers holding customers who are behaviourally identical.
-- Screenshot this. It IS the answer to the exercise.


-- The NTILE version of the segment table
WITH resegmented AS (
    SELECT monetary, recency_days, frequency,
           CASE
               WHEN r_score >= 4 AND f_score_ntile >= 4 THEN 'Champions'
               WHEN r_score <= 2 AND f_score_ntile >= 5 THEN 'Cannot Lose Them'
               WHEN r_score >= 3 AND f_score_ntile >= 3 THEN 'Loyal Customers'
               WHEN r_score <= 2 AND f_score_ntile >= 3 THEN 'At Risk'
               WHEN r_score  = 5 AND f_score_ntile <= 2 THEN 'New Customers'
               WHEN r_score  = 4 AND f_score_ntile <= 2 THEN 'Promising'
               WHEN r_score  = 3 AND f_score_ntile <= 2 THEN 'Needs Attention'
               WHEN r_score <= 2 AND f_score_ntile <= 2 THEN 'Hibernating'
               ELSE 'Others'
           END AS segment_ntile
    FROM rfm_customers
)
SELECT segment_ntile,
       COUNT(*)                                                     AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)           AS pct_customers,
       ROUND(SUM(monetary), 2)                                      AS revenue_brl,
       ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 2) AS pct_revenue,
       ROUND(AVG(frequency), 3)                                     AS avg_frequency
FROM resegmented
GROUP BY segment_ntile
ORDER BY revenue_brl DESC;

-- Side-by-side comparison of the two labellings.
-- The diagonal is agreement; everything off it is a customer
-- the two methods disagree about.
SELECT
    CASE WHEN r_score >= 4 AND f_score >= 4 THEN 'Champions'
         WHEN r_score <= 2 AND f_score >= 3 THEN 'At Risk'
         WHEN r_score <= 2 AND f_score <= 2 THEN 'Hibernating'
         ELSE 'Other' END AS rule_based,
    CASE WHEN r_score >= 4 AND f_score_ntile >= 4 THEN 'Champions'
         WHEN r_score <= 2 AND f_score_ntile >= 3 THEN 'At Risk'
         WHEN r_score <= 2 AND f_score_ntile <= 2 THEN 'Hibernating'
         ELSE 'Other' END AS ntile_based,
    COUNT(*) AS customers
FROM rfm_customers
GROUP BY rule_based, ntile_based
ORDER BY customers DESC;

/* YOUR TWO SENTENCES — write them yourself, but here's the shape:
   Sentence 1: why the numbers move (ties; NTILE must fill five
   equal buckets, so it splits an identical block of 1-order
   customers arbitrarily by row position).
   Sentence 2: which you'd show and why (the one whose segment
   boundaries correspond to a real behavioural difference, since
   a stakeholder will act on the labels).                        */
/* NTILE(5) forces five equally-sized buckets, but 97% of customers 
have exactly one order — so it splits a block of behaviourally identical 
customers across four tiers by row position rather than by anything real, 
reclassifying roughly 41,000 customers relative to the threshold-based score.

I'd show the threshold version, because a stakeholder will act on these labels: 
sending a loyalty reward to 16,586 "Champions" who have bought once wastes 
budget and, worse, teaches them the label means nothing. */

/* ============================================================
   EXERCISE 2 — ADD TENURE (the T in RFMT)

   The problem: recency alone can't distinguish
     (a) someone who joined last week and bought once  -> genuinely new
     (b) someone who joined 2 years ago and bought once -> churned
   Both look identical on R if they last ordered recently... and
   both look identical on F. Tenure separates them.

   first_order_at is NOT in rfm_customers, so we join back.
   ============================================================ */

WITH first_order AS (
    SELECT c.customer_unique_id AS person,
           MIN(o.order_purchase_timestamp) AS first_order_at
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled','unavailable')
      AND o.order_purchase_timestamp IS NOT NULL
    GROUP BY c.customer_unique_id
),
snapshot AS (
    SELECT DATE_ADD(DATE(MAX(order_purchase_timestamp)), INTERVAL 1 DAY) AS as_of
    FROM orders
),
with_tenure AS (
    SELECT rc.*,
           DATEDIFF(s.as_of, DATE(f.first_order_at)) AS tenure_days
    FROM rfm_customers rc
    JOIN first_order f ON f.person = rc.person
    CROSS JOIN snapshot s
)
SELECT
    segment,
    /* Buckets, not quintiles. Quintiles would be relative to this
       dataset; buckets mean the same thing next quarter. */
    CASE WHEN tenure_days <=  90 THEN '1. 0-3 months'
         WHEN tenure_days <= 180 THEN '2. 3-6 months'
         WHEN tenure_days <= 365 THEN '3. 6-12 months'
         ELSE                        '4. 12+ months'  END AS tenure_bucket,
    COUNT(*)                    AS customers,
    ROUND(AVG(frequency), 2)    AS avg_frequency,
    ROUND(AVG(monetary), 2)     AS avg_value_brl,
    ROUND(AVG(recency_days))    AS avg_recency_days
FROM with_tenure
GROUP BY segment, tenure_bucket
ORDER BY segment, tenure_bucket;

-- The cut that actually matters: split single-order customers by
-- how long they've been around. Same R, same F, very different
-- meaning — and very different action.
WITH first_order AS (
    SELECT c.customer_unique_id AS person,
           MIN(o.order_purchase_timestamp) AS first_order_at
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled','unavailable')
    GROUP BY c.customer_unique_id
),
snapshot AS (
    SELECT DATE_ADD(DATE(MAX(order_purchase_timestamp)), INTERVAL 1 DAY) AS as_of
    FROM orders
)
SELECT
    CASE WHEN DATEDIFF(s.as_of, DATE(f.first_order_at)) <= 90
         THEN 'Recently acquired, not yet repeated (winnable)'
         ELSE 'Long tenure, never repeated (likely lost)' END AS verdict,
    COUNT(*)                                                  AS customers,
    ROUND(SUM(rc.monetary), 2)                                AS revenue_brl,
    ROUND(AVG(rc.monetary), 2)                                AS avg_value_brl
FROM rfm_customers rc
JOIN first_order f ON f.person = rc.person
CROSS JOIN snapshot s
WHERE rc.frequency = 1
GROUP BY verdict;
/* This is a memo-ready split: the first group is a live
   reactivation target, the second is a write-off. Sizing them
   separately stops you recommending spend on the wrong one. */
/* verdict, customers, revenue_brl, avg_value_brl
Recently acquired, not yet repeated(winnable) |	8918 |	1415705.60 |	158.75
Long tenure, never repeated (likely lost) |	83177 |	13429562.93	| 161.46   */  

/* ============================================================
   EXERCISE 3 — REVIEW SCORE BY SEGMENT

   Hypothesis: At Risk / Hibernating customers had worse
   experiences. If true, retention is downstream of service, and
   the recommendation changes from "email them" to "fix delivery".

   CAREFUL: one order can have multiple review rows, and one
   customer has many orders. Average at the order level first,
   then at the customer level, or heavy buyers dominate.
   ============================================================ */

WITH order_review AS (
    -- collapse to one score per order
    SELECT order_id, AVG(review_score) AS order_score
    FROM order_reviews
    WHERE review_score IS NOT NULL
    GROUP BY order_id
),
customer_review AS (
    -- then one score per customer
    SELECT c.customer_unique_id      AS person,
           AVG(r.order_score)        AS avg_score,
           MIN(r.order_score)        AS worst_score,
           COUNT(*)                  AS reviews
    FROM orders o
    JOIN customers c    ON c.customer_id = o.customer_id
    JOIN order_review r ON r.order_id = o.order_id
    WHERE o.order_status NOT IN ('canceled','unavailable')
    GROUP BY c.customer_unique_id
)
SELECT
    rc.segment,
    COUNT(*)                                       AS customers_with_reviews,
    ROUND(AVG(cr.avg_score), 3)                    AS avg_review_score,
    /* % who ever left a 1 or 2 — a cleaner signal than the mean,
       because a bad experience is a distinct event, not a small
       shift in an average. */
    ROUND(100.0 * SUM(cr.worst_score <= 2) / COUNT(*), 2) AS pct_with_bad_review,
    ROUND(100.0 * SUM(cr.avg_score  >= 5) / COUNT(*), 2)  AS pct_all_five_star
FROM rfm_customers rc
JOIN customer_review cr ON cr.person = rc.person
GROUP BY rc.segment
ORDER BY avg_review_score ASC;

-- The direct causal-looking test, and the strongest version of
-- this analysis: did a bad FIRST experience prevent a second order?
WITH first_order AS (
    SELECT c.customer_unique_id AS person, o.order_id,
           ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id
                              ORDER BY o.order_purchase_timestamp) AS rn
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled','unavailable')
),
order_review AS (
    SELECT order_id, AVG(review_score) AS order_score
    FROM order_reviews WHERE review_score IS NOT NULL GROUP BY order_id
)
SELECT
    ROUND(r.order_score)                                  AS first_review_score,
    COUNT(*)                                              AS customers,
    SUM(rc.frequency > 1)                                 AS repeaters,
    ROUND(100.0 * SUM(rc.frequency > 1) / COUNT(*), 2)    AS repeat_rate_pct
FROM first_order f
JOIN order_review r  ON r.order_id = f.order_id
JOIN rfm_customers rc ON rc.person = f.person
WHERE f.rn = 1
GROUP BY first_review_score
ORDER BY first_review_score;
/* Read the trend across 1 to 5 stars. A clean monotonic rise
   means experience quality predicts repeat purchase. Note the
   caveat honestly: unhappy people both leave bad reviews AND
   don't return, so this is correlation with a plausible
   direction, not proof. Saying that out loud is a plus. */
