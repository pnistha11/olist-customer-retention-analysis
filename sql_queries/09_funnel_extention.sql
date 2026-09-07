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
with delivered as (
	select 
		c.customer_state as state,
        timestampdiff(day, o.order_purchase_timestamp,
						o.order_delivered_customer_date) as days_to_deliver,
		/* late = arrrivee after the date the customer was promissed.
			boolean, si sum() counts them */
            (o.order_delivered_customer_date > o.order_estimated_delivery_date) as was_late
		from orders o
        join customers c on c.customer_id = o.customer_id
        where o.order_delivered_customer_date is not null
			and o.order_purchase_timestamp is not null
            and o.order_status not in ('canceled', 'unavailable')
),
ranked as (
	select state, days_to_deliver, was_late,
		row_number() over (partition by state order by days_to_deliver) as rn,
        count(*) over (partition by state) as n
	from delivered
    where days_to_deliver >= 0 -- a few rows have inverted timestamps
)
select
	state,
    max(n) as orders,
    /* median: middle row (odd n) or average of middle two (even n) */
    round(avg(case when rn in (floor((n+1)/2), ceil((n+1)/2))
				then days_to_deliver end), 1) as median_days,
	/* p90: the slow tail, where the angry customers are */
    max(case when rn = ceil(0.90 * n) then days_to_deliver end) as p90_days,
    round(avg(days_to_deliver), 1) as mean_days,
    round(100.0 * sum(was_late)/count(*), 2) as pct_late
from ranked
group by state
having orders >= 200 -- drop tiny sates; their medians are noise
order by median_days desc;

/* ============================================================
   EXERCISE 2 — FUNNEL BY MONTH

   Question: is drop-off getting better or worse?

   A static funnel says where you lose orders. A funnel over
   time says whether anyone is fixing it. That difference
   turns an observation into a trend.

   Grouping is by the month the order was PLACED, so each
   order stays in one cohort regardless of when it delivered.
   ============================================================ */
with base as (
	select 
		cast(date_format(o.order_purchase_timestamp,'%Y-%m-01')as date) as month,
		o.order_approved_at as t_approved,
        o.order_delivered_carrier_date as t_shipped,
        o.order_delivered_customer_date as t_delivered,
        timestampdiff(day, o.order_purchase_timestamp,
					o.order_delivered_customer_date) as days_to_deliver
	from orders o
    where o.order_purchase_timestamp is not null
)
select
	month,
    count(*) as placed,
    /* Same forced nesting as the main funnel: you can't be
       delivered without having been approved and shipped. */
	round(100.0 * sum(t_approved is not null) / count(*), 2) as pct_approved,
    round(100.0 * sum(t_approved is not null
			and t_shipped is not null) / count(*), 2) as pct_shipped,
	round(100.0 * sum(t_approved is not null
			and t_shipped is not null and t_delivered is not null) / count(*), 2) as pct_delivered,
	round(avg(days_to_deliver), 1 ) as avg_days_to_deliver
from base
where month between '2017-01-01' and '2018-08-01'
group by month
order by month;

/* ============================================================
   EXERCISE 3 — HOW MANY STARS DOES LATENESS COST?

   Question: quantify the relationship between delivery delay
   and review score.

   This is the query that connects operations to customer
   sentiment. If each extra day late costs measurable stars,
   the delivery problem has a number attached to it.
   ============================================================ */
with order_review as (
	-- one score per order (an order can have several review rows)
    select order_id, avg(review_score) as order_score
    from order_reviews
    where review_score is not null
    group by order_id
),
lateness as (
	select
		r.order_score,
         /* Negative = arrived early, positive = arrived late.
           Measuring against the PROMISED date, not raw transit
           time, because customers judge against expectation. */
		datediff(o.order_delivered_customer_date,
				o.order_estimated_delivery_date) as days_late
	from orders o
    join order_review r on r.order_id = o.order_id
    where o.order_delivered_customer_date is not null
		and	o.order_estimated_delivery_date is not null
        and o.order_status not in ('canceled','unavailable')
)
select
	case
		when days_late < -7 then '1. more than a week early'
        when days_late < 0 then '2. early'
        when days_late = 0 then '3. on the promised day'
        when days_late <= 3 then '4. 1-3 days late'
        when days_late <= 7 then '5. 4-7 days late'
        when days_late <= 14 then '6. 1-2 weeks late'
        else		'7. more than 2 weeks late'
	end as delivery_vs_promise,
	count(*) as orders,
    round(avg(order_score), 2) as avg_review_score,
    round(100.0 * sum(order_score <= 2) / count(*), 1) as pct_1_or_2_star,
    round(100.0 * sum(order_score >= 5) / count(*), 1) as pct_5_star
from lateness
group by delivery_vs_promise
order by delivery_vs_promise;

-- the single number version: stars lost per day late.
-- A crude linear slope, but it fits in one sentence of a memo.
with order_review as (
	select order_id, avg(review_score) as order_score
    from order_reviews where review_score is not null 
	group by order_id
),
lateness as (
	select r.order_score as y,
		datediff(o.order_delivered_customer_date,
			o.order_estimated_delivery_date) as x
	from orders o
    join order_review r on r.order_id = o.order_id
    where o.order_delivered_customer_date is not null
		and o.order_estimated_delivery_date is not null
        and o.order_status not in ('canceled', 'unavailable')
)
select
	count(*) as orders,
	/* Least-squares slope, written out longhand:
	slope = (n*Sxy - Sx*Sy) / (n*Sxx - Sx^2)       */
    round(
		(count(*) * sum(x*y) - sum(x) * sum(y)) /
        (count(*) * sum(x*x) - sum(x) * sum(x))
        ,4) as stars_per_day_late,
        round(avg(y), 3) as mean_score
from lateness
where x between -30 and 60;


WITH base AS (
    SELECT o.order_id,
           o.order_purchase_timestamp      AS t_placed,
           o.order_delivered_customer_date AS t_delivered
    FROM orders o
    WHERE o.order_purchase_timestamp IS NOT NULL
),
durations AS (
    SELECT TIMESTAMPDIFF(MINUTE, t_placed, t_delivered) AS mins
    FROM base WHERE t_delivered IS NOT NULL
),
ranked AS (
    SELECT mins,
           ROW_NUMBER() OVER (ORDER BY mins) AS rn,
           COUNT(*)     OVER ()              AS n
    FROM durations WHERE mins >= 0
)
SELECT
    MAX(n) AS delivered_orders,
    ROUND(AVG(CASE WHEN rn IN (FLOOR((n+1)/2), CEIL((n+1)/2))
                   THEN mins END) / 1440.0, 1)          AS median_days,
    ROUND(MAX(CASE WHEN rn = CEIL(0.90 * n) THEN mins END) / 1440.0, 1) AS p90_days,
    ROUND(AVG(mins) / 1440.0, 1)                        AS mean_days
FROM ranked;