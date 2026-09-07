/* ============================================================
   DELIVERABLE 2 — ORDER FUNNEL WITH DROP-OFF
   placed -> approved -> shipped -> delivered -> reviewed
   Conversion rate + median time at each stage.
   ============================================================ */
use olist;

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
with base as (
	select
		o.order_id,
        o.order_purchase_timestamp as t_placed,
        o.order_approved_at as t_approved,
        o.order_delivered_carrier_date as t_shipped,
        o.order_delivered_customer_date as t_delivered,
        r.t_reviewed
	from orders o
    left join (
		-- an order can have several review rows; keep the earliest
        select order_id, min(review_creation_date) as t_reviewed
        from order_reviews
        where review_creation_date is not null
        group by order_id
    ) r on r.order_id = o.order_id
    where o.order_purchase_timestamp is not null
),

-- force monotonic nesting : you can't reach stage N without N-1
nested as (
	select
		order_id,
        1 as s_placed,
        (t_approved is not null) as s_approved,
        (t_approved is not null and t_shipped is not null) as s_shipped,
        (t_approved is not null and t_shipped is not null and
			t_delivered is not null) as s_delivered,
		(t_approved is not null and t_shipped is not null and
			t_delivered is not null and t_reviewed is not null) as s_reviewed
	from base
),
funnel as (
	select 1 as step_no, '1. Placed' as stage, sum(s_placed) as orders from nested
    union all
    select 2, '2. Approved' , sum(s_approved) from nested union all
    select 3, '3. Shipped', sum(s_shipped) from nested union all
    select 4, '4. Delivered' , sum(s_delivered) from nested union all
    select 5, '5. Reviewed', sum(s_reviewed) from nested
)
select stage, orders,
	/* survival from the top of the funnel */
    round(100.0 * orders / first_value(orders) over (order by step_no), 2) as pct_of_placed,
    /* conversion from the immediately preceding stage */
    round(100.0 * orders / lag(orders) over (order by step_no), 2) as step_conversion_pct,
    /* absolute bodies lost at this step — this is what a category
       manager actually reacts to */
	lag(orders) over (order by step_no) - orders as dropped_here
from funnel
order by step_no;

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
with base as (
	select o.order_id,
			o.order_purchase_timestamp as t_placed,
            o.order_approved_at as t_approved,
            o.order_delivered_carrier_date as t_shipped,
            o.order_delivered_customer_date as t_delivered,
            r.t_reviewed
		from orders o
        left join (
			select order_id, min(review_creation_date) as t_reviewed
            from order_reviews
            where review_creation_date is not null
            group by order_id
        ) r on r.order_id = o.order_id
        where o.order_purchase_timestamp is not null
),

/* Unpivot each order into one row per completed transition. */
durations as (
	select 1 as step_no, 'placed -> approved' as transition,
		timestampdiff(minute, t_placed, t_approved) as mins
	from base where t_approved is not null
    union all
    select 2 , 'approved -> shipped',
		timestampdiff(minute, t_approved, t_shipped)
	from base where t_approved is not null and t_shipped is not null
    union all
    select 3, 'shipped -> delivered',
		timestampdiff(minute, t_shipped, t_delivered)
	from base where t_shipped is not null and t_delivered is not null
    union all
    select 4, 'delivered -> reviewed',
		timestampdiff(minute, t_delivered,t_reviewed)
	from base where t_delivered is not null and t_reviewed is not null
    union all
    select 4, 'delivered -> reviewed',
		timestampdiff(minute,t_delivered,t_reviewed)
	from base where t_delivered is not null and t_reviewed is not null
    union all
    select 5, 'placed -> delivered(end to end)',
		timestampdiff(minute,t_placed, t_delivered)
	from base where t_delivered is not null
),
ranked as (
	select 
		step_no, transition, mins,
        row_number() over (partition by step_no order by mins) as rn,
        count(*) over (partition by step_no) as n
	from durations
    where mins >= 0
)

select transition,
	max(n) as n_orders,
    round(avg(case when rn in (floor((n+1)/2), ceil((n+1)/2))
				then mins end) / 60.0, 1) as median_hours,
	round(avg(case when rn in (floor((n+1)/2), ceil((n+1)/2))
			then mins end)/ 1440.0,2) as median_days,
	round(avg(mins)/ 1440.0,2) as mean_days,
    /* p90 shows the tail — the customers who are actually angry */
    round(max(case when rn = ceil(0.90 * n) then mins end) / 1440.0, 2) as p90_days
from ranked
group by step_no , transition
order by step_no;
/* Reading the output: median approval is under a day, median
   end-to-end delivery lands around 10-11 days, but the p90 is
   roughly triple the median. Averages hide that; the p90 is the
   number worth putting in a memo. */
   
/* ------------------------------------------------------------
   THE ANOMALY — quantify it so you can mention it credibly
   ------------------------------------------------------------ */
select
	sum(o.order_delivered_customer_date is not null) as delivered_orders,
    sum(r.order_id is not null) as orders_with_review,
    sum(r.order_id is not null and
			o.order_delivered_customer_date is null) as reviewed_but_not_delivered
from orders o
left join (select distinct order_id from order_reviews) r
			on r.order_id = o.order_id;

--  WHERE THE MONEY LEAKS — attach R$ to the drop-off
select 
	o.order_status,
    count(distinct o.order_id) as orders,
    round(sum(i.price + i.freight_value), 2) as gmv_brl,
    round(100.0 * sum(i.price + i.freight_value) / 
			sum(sum(i.price + i.freight_value)) over (), 2) as pct_gmv
from orders o
join order_items i on i.order_id = o.order_id
group by o.order_status
order by gmv_brl desc;
