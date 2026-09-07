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
/* Query 1 — the cohort table
cust_orders */ 
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


/* ------------------------------------------------------------
   SUPPORTING NUMBERS FOR THE MEMO
   ------------------------------------------------------------ */
-- 1) Headline repeat rate, one number.
select 
	count(*) as total_customers,
    sum(order_count > 1) as repeat_customers,
    round(100.0 * sum(order_count > 1) / count(*), 2) as repeat_rate_pct
from (
	select c.customer_unique_id, count(distinct o.order_id) as order_count
    from orders o
    join customers c on c.customer_id = o.customer_id
    where o.order_status not in ('canceled', 'unavailable')
    group by c.customer_unique_id
) x;

-- 2) When repeat buyers DO come back, how long does it take?
-- MySQL has no MEDIAN(), so we rank rows and take the middle.
with gaps as (
	select
		c.customer_unique_id as person,
        timestampdiff(
			day,
            lag(o.order_purchase_timestamp) over (
				partition by c.customer_unique_id
                order by o.order_purchase_timestamp),
			o.order_purchase_timestamp
        ) as days_since_prev
	from orders o
    join customers c on c.customer_id = o.customer_id
    where o.order_status not in ('canceled', 'unavailable')
),
clean as (
	select days_since_prev as d,
		row_number() over (order by days_since_prev) as rn,
        count(*) over () as n
	from gaps
    where days_since_prev is not null
)
select 
	max(n) as repeat_purchase_events,
    round(avg(case when rn in (floor((n+1)/2), ceil(n+1)/2) 
			then d end) , 1) as median_days_between,
	round(avg(d), 1) as mean_days_between
from clean;

-- 3) Does a bad delivery experience kill the repeat purchase?
with first_order as (
	select
		c.customer_unique_id as person,
        o.order_id,
        o.order_delivered_customer_date,
        o.order_estimated_delivery_date,
        row_number() over (partition by c.customer_unique_id
					order by o.order_purchase_timestamp) as rn
		from orders o
        join customers c on c.customer_id = o.customer_id
        where o.order_status not in ('canceled', 'unavailable')
),
totals as (
	select 
		c.customer_unique_id as person,
        count(distinct o.order_id) as n_orders
	from orders o
    join customers c on c.customer_id = o.customer_id
    where o.order_status not in ('canceled', 'unavailable')
    group by c.customer_unique_id
)
select 
	case
		when f.order_delivered_customer_date is null then 'never delivered'
        when f.order_delivered_customer_date > f.order_estimated_delivery_date
			then 'late'
		else 'on time'
	end as first_delivery,
    count(*) as customers,
    round(100.0 * sum(t.n_orders > 1) / count(*) ,2) as repeat_rate_pct
from first_order f
join totals t on t.person = f.person
where f.rn = 1
group by first_delivery
order by repeat_rate_pct desc;


select COUNT(*) as unique_customers,
       SUM(case when n_orders > 1 then 1 else 0 end) as repeaters,
       ROUND(100.0 * SUM(case when n_orders > 1 then 1 else 0 end) / COUNT(*), 2) as repeat_pct
from (
    select c.customer_unique_id, COUNT(*) as n_orders
    from orders o
    join customers c on c.customer_id = o.customer_id
    group by 1
) t;

select round(avg(order_revenue), 2) as avg_order_value_brl,
       COUNT(*) as orders
from (
    select o.order_id, SUM(i.price + i.freight_value) as order_revenue
    from orders o
    join order_items i on i.order_id = o.order_id
    where o.order_status not in ('canceled','unavailable')
    group by o.order_id
) x;

SELECT
    SUM(o.order_delivered_customer_date IS NOT NULL)  AS delivered_orders,
    SUM(r.order_id IS NOT NULL)                       AS orders_with_review,
    SUM(r.order_id IS NOT NULL
        AND o.order_delivered_customer_date IS NULL)  AS reviewed_but_not_delivered
FROM orders o
LEFT JOIN (SELECT DISTINCT order_id FROM order_reviews) r
       ON r.order_id = o.order_id;