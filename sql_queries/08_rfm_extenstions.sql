-- RFM EXTENSIONS
use olist;

/* ============================================================
   EXERCISE 1 — NTILE vs RULE-BASED FREQUENCY SCORE

   Identical to the main segment table with one substitution:
   f_score_ntile replaces f_score everywhere in the CASE.
   Run the diagnostic first so you can see WHY the numbers move.
   ============================================================ */

-- Diagnostic: does NTILE actually separate anyone on frequency?
select f_score_ntile,
		count(*) as customers,
        min(frequency) as min_freq,
        max(frequency) as max_freq
from rfm_customers
group by f_score_ntile
order by f_score_ntile;

-- the ntile version of the segment table
with resegmented as (
	select monetary, recency_days,frequency,
		case
			when r_score >= 4 and f_score_ntile >= 4 then 'Champions'
            when r_score >= 2 and f_score_ntile >= 5 then 'Cannot Lose Them'
            when r_score >= 3 and f_score_ntile >= 3 then 'Loyal Customers'
            when r_score <= 2 and f_score_ntile >= 3 then 'At Risk'
            when r_score = 5 and f_score_ntile <= 2 then 'New Customers'
            when r_score = 4 and f_score_ntile <= 2 then 'Promising'
            when r_score = 3 and f_score_ntile <= 2 then 'Needs Attention'
            when r_score <= 2 and f_score_ntile <= 2 then 'Hibernating'
			else 'Others'
		end as segment_ntile
	from rfm_customers
)
select segment_ntile,
		count(*) as customers,
        round(100.0 * count(*) / sum(count(*)) over (), 2) as pct_customers,
        round(sum(monetary), 2) as revenue_brl,
        round(100.0 * sum(monetary) / sum(sum(monetary)) over () ,2) as pct_revenue,
        round(avg(frequency), 3) as avg_frequency
from resegmented
group by segment_ntile
order by revenue_brl desc;

-- Side-by-side comparison of the two labellings.
-- The diagonal is agreement; everything off it is a customer
-- the two methods disagree about.
select 
	case
		when r_score >= 4 and f_score >= 4 then 'Champions'
        when r_score >= 2 and f_score >= 3 then 'at risk'
        when r_score <= 2 and f_score <= 2 then 'Hibernating'
        else 'Other' end as rule_based,
	case
		when r_score >= 4 and f_score_ntile >= 4 then 'Champions'
        when r_score <= 2 and f_score_ntile >= 3 then 'at risk'
        when r_score <= 2 and f_score_ntile <= 2 then 'Hibernating'
        else 'other' end as ntile_based,
	count(*) as customers
from rfm_customers
group by rule_based, ntile_based
order by customers desc;
SELECT f_score_ntile, COUNT(*), MIN(frequency), MAX(frequency)
FROM rfm_customers GROUP BY f_score_ntile ORDER BY f_score_ntile;

/* ============================================================
   EXERCISE 2 — ADD TENURE (the T in RFMT)

   The problem: recency alone can't distinguish
     (a) someone who joined last week and bought once  -> genuinely new
     (b) someone who joined 2 years ago and bought once -> churned
   Both look identical on R if they last ordered recently... and
   both look identical on F. Tenure separates them.

   first_order_at is NOT in rfm_customers, so we join back.
   ============================================================ */
   with first_order as (
	select c.customer_unique_id as person,
			min(o.order_purchase_timestamp) as first_order_at
	from orders o
    join customers c on c.customer_id = o.customer_id
    where o.order_status not in ('canceled', 'unavailable')
		and o.order_purchase_timestamp is not null
	group by c.customer_unique_id
  ),
  snapshot as (
	select date_add(date(max(order_purchase_timestamp)), interval 1 day) as as_of
    from orders
  ),
  with_tenure as (
		select rc.*,
			datediff(s.as_of, date(f.first_order_at)) as tenure_days
		from rfm_customers rc
        join first_order f on f.person = rc.person
        cross join snapshot s
)
select 
	segment,
    /* Buckets, not quintiles. Quintiles would be relative to this
       dataset; buckets mean the same thing next quarter. */
	case
		when tenure_days <= 90 then '1. 0-3 months'
        when tenure_days <= 180 then '2. 3-6 months'
        when tenure_days <= 365 then '3. 6-12 months'
        else 			'4. 12+ months' end as tenure_bucket,
	count(*) as customers,
    round(avg(frequency), 2) as avg_frequency,
    round(avg(monetary), 2) as avg_value_brl,
    round(avg(recency_days)) as avg_recency_days
from with_tenure
group by segment, tenure_bucket
order by segment, tenure_bucket;

-- The cut that actually matters: split single-order customers by
-- how long they've been around. Same R, same F, very different
-- meaning — and very different action.
with first_order as (
	select c.customer_unique_id as person,
		min(o.order_purchase_timestamp) as first_order_at
	from orders o
    join customers c on c.customer_id = o.customer_id
    where o.order_status not in ('canceled', 'unavailable')
    group by c.customer_unique_id
),
snapshot as (
	select date_add(date(max(order_purchase_timestamp)), interval 1 day) as as_of
    from orders
)
select
	case when datediff(s.as_of, date(f.first_order_at)) <= 90
		then 'Recently acquired, not yet repeated(winnable)'
        else 'Long tenure, never repeated (likely lost)' end as verdict,
	count(*) as customers,
    round(sum(rc.monetary), 2) as revenue_brl,
    round(avg(rc.monetary), 2) as avg_value_brl
from rfm_customers rc
join first_order f on f.person = rc.person
cross join snapshot s
where rc.frequency = 1
group by verdict;
/* This is a memo-ready split: the first group is a live
   reactivation target, the second is a write-off. Sizing them
   separately stops you recommending spend on the wrong one. */

/* ============================================================
   EXERCISE 3 — REVIEW SCORE BY SEGMENT

   Hypothesis: At Risk / Hibernating customers had worse
   experiences. If true, retention is downstream of service, and
   the recommendation changes from "email them" to "fix delivery".

   CAREFUL: one order can have multiple review rows, and one
   customer has many orders. Average at the order level first,
   then at the customer level, or heavy buyers dominate.
   ============================================================ */
with order_review as (
	-- collapse to one score per order
    select order_id, avg(review_score) as order_score
    from order_reviews
    where review_score is not null
	group by order_id
),
customer_review as (
	-- then one score per customer
    select c.customer_unique_id      as person,
           avg(r.order_score)        as avg_score,
           min(r.order_score)        as worst_score,
		   count(*) as reviews
	from orders o
    join customers c on c.customer_id = o.customer_id
    join order_review r on r.order_id = o.order_id
    where o.order_status not in ('canceled', 'unavailable')
    group by c.customer_unique_id
)
select
	rc.segment,
    count(*) as customers_with_reviews,
    round(avg(cr.avg_score), 3) as avg_review_score,
    /* % who ever left a 1 or 2 — a cleaner signal than the mean,
       because a bad experience is a distinct event, not a small
       shift in an average. */
	round(100.0 * sum(cr.worst_score <= 2) / count(*) ,2) as pct_with_bad_review,
    round(100.0 * sum(cr.worst_score >=5) / count(*), 2) as pac_all_five_star
from rfm_customers rc
join customer_review cr on cr.person = rc.person
group by rc.segment
order by avg_review_score asc;

-- the direct causal-looking test, and the strongest version of
-- this analysis : did a bad first experience prevent a second order?
with first_order as (
	select c.customer_unique_id as person, o.order_id,
		row_number() over (partition by c.customer_unique_id
							order by o.order_purchase_timestamp) as rn
	from orders o
    join customers c on c.customer_id = o.customer_id
    where o.order_status not in ('canceled', 'unavailable')
),
order_review as (
	select order_id, avg(review_score) as order_score
    from order_reviews where review_score is not null group by order_id
)
select
	round(r.order_score) as first_review_score,
    count(*) as customers,
    sum(rc.frequency > 1) as repeaters,
    round(100.0 * sum(rc.frequency > 1) / count(*) , 2) as repeat_rate_pct
from first_order f
join order_review r on r.order_id = f.order_id
join rfm_customers rc on rc.person = f.person
where f.rn = 1
group by first_review_score
order by first_review_score;