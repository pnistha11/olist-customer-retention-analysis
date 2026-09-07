-- DOES REPEAT RATE DIFFER BY STATE?
with cust_orders as (
	select 
		c.customer_unique_id as person,
        o.order_purchase_timestamp as ts,
        c.customer_state as state
	from orders o
    join customers c on c.customer_id = o.customer_id
    where o.order_status not in ('canceled' , 'unavailable')
		and o.order_purchase_timestamp is not null
),

stamped as (
	select person, ts,
		min(ts) over (partition by person) as first_ts,
        first_value(state) over (partition by person order by ts) as home_state
	from cust_orders
),
indexed as (
	select person, home_state,
		cast(date_format(first_ts, '%Y-%m-01') as date) as cohort_month,
        timestampdiff(month,
			cast(date_format(first_ts, '%Y-%m-01')as date),
            cast(date_format(ts, '%Y-%m-01') as date)) as month_index
	from stamped
),

/* Fair-window filter. Everyone here gets exactly 3 months of
   observation, so states are comparable. */
eligible as (
	select * from indexed
    where cohort_month between '2017-01-01' and '2018-04-01'
),

/* Collapse to one row per person: did they return in months 1-3?
   MAX(condition) returns 1 if the condition was true on ANY of
   that person's rows, 0 otherwise. It's "did this ever happen"
   written as an aggregate. */
per_person as (
	select person, home_state,
		max(month_index between 1 and 3 ) as returned_in_90d
	from eligible
    group by person, home_state
)

select 
	home_state as state,
    count(*) as customers,
    sum(returned_in_90d) as repeaters,
    round(100.0 * sum(returned_in_90d) /  count(*), 2) as repeat_rate_pct
from per_person
group by home_state
having customers >= 500
order by repeat_rate_pct desc;

-- DOES THE FIRST PRODUCT PREDICT REPEAT?
/* Question: some categories are naturally one-and-done (you buy
   one mattress). Others should repeat (cosmetics, pet supplies).
   Which categories repeat less than their nature suggests? */

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


-- REVENUE RETENTION INSTEAD OF CUSTOMER RETENTION
/* 
Same grid, different unit. Instead of "what % of people came
back", this asks "what % of the cohort's first-month revenue
did we earn again in month N".
*/
with order_value as (
	select order_id, sum(price + freight_value) as rev
    from order_items
    group by order_id
),
cust_orders as (
	select c.customer_unique_id as person,
    o.order_purchase_timestamp as ts,
    coalesce(v.rev ,0) as rev
    from orders o
    join customers c on c.customer_id = o.customer_id
    left join order_value v on v.order_id = o.order_id
    where o.order_status not in ('canceled','unavailable')
    and o.order_purchase_timestamp is not null
),

stamped as (
	select
		person, ts, rev,
        min(ts) over (partition by person) as first_ts
	from cust_orders
),

indexed AS (
    SELECT rev,
           CAST(DATE_FORMAT(first_ts,'%Y-%m-01') AS DATE) AS cohort_month,
           TIMESTAMPDIFF(MONTH,
               CAST(DATE_FORMAT(first_ts,'%Y-%m-01') AS DATE),
               CAST(DATE_FORMAT(ts,'%Y-%m-01') AS DATE)) AS month_index
    FROM stamped
),

base_revenue as (
	select cohort_month, sum(rev) as month0_revenue
    from indexed
    where month_index = 0
    group by cohort_month
),
 
cell_revenue as(
	select cohort_month, month_index, sum(rev) as cell_revenue
    from indexed
    group by cohort_month, month_index
)

select c.cohort_month,
		round(b.month0_revenue, 2) as month0_revenue_brl,
        c.month_index,
        round(c.cell_revenue, 2) as cell_revenue_brl,
        round(100.0 * c.cell_revenue / b.month0_revenue, 2) as pct_revenue_retained
from cell_revenue c
join base_revenue b on b.cohort_month = c.cohort_month
where c.month_index between 0 and 12
	and c.cohort_month between '2017-01-01' and '2018-07-01'
order by c.cohort_month, c.month_index;