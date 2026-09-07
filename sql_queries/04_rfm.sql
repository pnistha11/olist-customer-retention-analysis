/* ============================================================
   DELIVERABLE 3 — RFM SEGMENTATION
   NTILE(5) quintiles on Recency / Frequency / Monetary,
   mapped to named segments, sized by customers and revenue.
   ============================================================ */
use olist;

with snapshot as (
	-- "Today" = day after the last order in the dataset.
    select date_add(date(max(order_purchase_timestamp)), interval 1 day) as as_of
    from orders
),

order_value as (
	-- Revenue = item price + freight, summed per order.
    -- Alternative: SUM(payment_value) from order_payments. That
    -- includes vouchers and installment quirks and won't tie out
    -- exactly. Pick one, state it, stay consistent.
    select order_id, sum(price + freight_value) as order_revenue
    from order_items
    group by order_id
),

customer_base  as (
	select
		c.customer_unique_id as person,
		max(o.order_purchase_timestamp) as last_order_at,
        count(distinct o.order_id) as frequency,
        coalesce(sum(v.order_revenue), 0) as monetary
	from orders o
    join customers c on c.customer_id = o.customer_id
    left join order_value v on v.order_id = o.order_id
    where o.order_status not in ('canceled', "unavailable")
		and o.order_purchase_timestamp is not null
	group by c.customer_unique_id
    having monetary > 0
),

rfm_raw as (
	select 
		b.person,
        datediff(s.as_of, date(b.last_order_at)) as recency_days,
        b.frequency,
        round(b.monetary, 2) as monetary
	from customer_base b
    cross join snapshot s
),

scored as (
	select
    	person ,recency_days, frequency, monetary,
        /* Recency: fewer days = better. Order DESC so the biggest
           recency_days lands in tile 1 and the freshest in tile 5.
           After this, 5 is always "good" for every dimension. */
		ntile(5) over (order by recency_days desc) as r_score,
        
        -- The literal NTILE frequency score — kept for comparison
        ntile(5) over (order by frequency asc) as f_score_ntile,
        
        -- the honest frequency score
        case  when frequency >= 3 then 5
			when frequency = 2 then 3
            else 1 end as f_score,
            
		ntile(5) over (order by monetary asc) as m_score
	from rfm_raw
),

segmented as (
	select 
		s.*,
        concat(r_score, f_score, m_score) as rfm_cell,
        case 
			when r_score >= 4 and f_score >= 4 then 'Champions'
            when r_score <= 2 and f_score >= 5 then 'Cannot Lose Them'
            when r_score >= 3 and f_score >= 3 then 'Loyal Customers'
            when r_score <= 2 and f_score >= 3 then 'At Risk'
            when r_score  = 5 and f_score <= 2 then 'New Customers'
            when r_score  = 4 and f_score <= 2 then 'Promising'
            when r_score  = 3 and f_score <= 2 then 'Needs Attention'
            when r_score <= 2 and f_score <= 2 then 'Hibernating'
            else 'Others'
        end as segment
    from scored s
)

/* ---------- MAIN OUTPUT: segment sizes and revenue share ---------- */
select segment,
	count(*) as customers,
    round(100.0 * count(*) / sum(count(*)) over (), 2) as pct_customers,
    round(sum(monetary), 2) as revenue_brl,
    round(100.0 * sum(monetary) / sum(sum(monetary)) over (), 2) as pct_revenue,
    round(avg(monetary), 2) as avg_value_brl,
    round(avg(recency_days)) as avg_recency_days,
    round(avg(frequency), 2) as avg_frequency
from segmented
group by segment
order by revenue_brl desc;

drop table if exists rfm_customers;
create table rfm_customers as 
with snapshot as (
	-- "Today" = day after the last order in the dataset.
    select date_add(date(max(order_purchase_timestamp)), interval 1 day) as as_of
    from orders
),

order_value as (
	-- Revenue = item price + freight, summed per order.
    -- Alternative: SUM(payment_value) from order_payments. That
    -- includes vouchers and installment quirks and won't tie out
    -- exactly. Pick one, state it, stay consistent.
    select order_id, sum(price + freight_value) as order_revenue
    from order_items
    group by order_id
),

customer_base  as (
	select
		c.customer_unique_id as person,
		max(o.order_purchase_timestamp) as last_order_at,
        count(distinct o.order_id) as frequency,
        coalesce(sum(v.order_revenue), 0) as monetary
	from orders o
    join customers c on c.customer_id = o.customer_id
    left join order_value v on v.order_id = o.order_id
    where o.order_status not in ('canceled', "unavailable")
		and o.order_purchase_timestamp is not null
	group by c.customer_unique_id
    having monetary > 0
),

rfm_raw as (
	select 
		b.person,
        datediff(s.as_of, date(b.last_order_at)) as recency_days,
        b.frequency,
        round(b.monetary, 2) as monetary
	from customer_base b
    cross join snapshot s
),

scored as (
	select
    	person ,recency_days, frequency, monetary,
        /* Recency: fewer days = better. Order DESC so the biggest
           recency_days lands in tile 1 and the freshest in tile 5.
           After this, 5 is always "good" for every dimension. */
		ntile(5) over (order by recency_days desc) as r_score,
        
        -- The literal NTILE frequency score — kept for comparison
        ntile(5) over (order by frequency asc) as f_score_ntile,
        
        -- the honest frequency score
        case  when frequency >= 3 then 5
			when frequency = 2 then 3
            else 1 end as f_score,
            
		ntile(5) over (order by monetary asc) as m_score
	from rfm_raw
)
select 
	s.*,
    concat(r_score, f_score, m_score) as rfm_cell,
        case 
			when r_score >= 4 and f_score >= 4 then 'Champions'
            when r_score <= 2 and f_score >= 5 then 'Cannot Lose Them'
            when r_score >= 3 and f_score >= 3 then 'Loyal Customers'
            when r_score <= 2 and f_score >= 3 then 'At Risk'
            when r_score  = 5 and f_score <= 2 then 'New Customers'
            when r_score  = 4 and f_score <= 2 then 'Promising'
            when r_score  = 3 and f_score <= 2 then 'Needs Attention'
            when r_score <= 2 and f_score <= 2 then 'Hibernating'
            else 'Others'
        end as segment
    from scored s;

create index ix_rfm_segment on rfm_customers (segment);
/* ------------------------------------------------------------
   SUPPORTING CUTS
   ------------------------------------------------------------ */
select f_score_ntile,
	count(*) as customers,
    min(frequency) as min_freq,
    max(frequency) as max_freq
from rfm_customers
group by f_score_ntile
order by f_score_ntile;
-- Tiles 1-4 will all be min=1, max=1. That is the tie problem,
-- visible in one screenshot. Put this in your write-up.

-- Pareto check: what share of revenue comes from the top 20%?
with ranked as (
	select monetary,
		ntile(5) over (order by monetary desc) as value_quintile
	from rfm_customers
)
select value_quintile,
	count(*) as customers,
    round(sum(monetary), 2) as revenue_brl,
    round(100.0 * sum(monetary) / sum(sum(monetary)) over (), 2) as pct_revenue
from ranked
group by value_quintile
order by value_quintile;

-- which categories do the highest-value customers buy first?
-- (acquisition lever : recruti more people into the good cohort.)
select category,
	count(*) as high_value_customers,
    round(avg(monetary), 2) as avg_customer_brl,
    round(sum(monetary), 2) as total_value_brl
from (
	/* Deduplicate FIRST. One row per (customer, category), no
       matter how many items they bought in it. DISTINCT over
       three columns keeps a customer who bought in two different
       categories in both groups — which is what we want — while
       collapsing their four purchases within one category to a
       single row. Safe to include monetary in the DISTINCT
       because it's fixed per person, so it can't split them. */
		select distinct
         rc.person,
         rc.monetary,
         coalesce( t.product_category_name_english,
					p.product_category_name,
                    'unknown') as category
		from rfm_customers rc
        join customers c on c.customer_unique_id = rc.person
        join orders o on o.customer_id = c.customer_id
        join order_items i on i.order_id = o.order_id
        join products p on p.product_id = i.product_id
        left join category_translation t
				on t.product_category_name = p.product_category_name
		where rc.m_score = 5
			and o.order_status not in ('canceled', 'unavailable')
) d
group by category
having count(*) >= 100
order by high_value_customers desc
limit 15;

describe category_translation;
alter table category_translation
  change product_category_name_engilsh product_category_name_english varchar(64);

select count(*) from rfm_customers;
select m_score, count(*) from rfm_customers group by m_score order by m_score;
select count(*) from rfm_customers rc
join customers c on c.customer_unique_id = rc.person;
select count(*) from rfm_customers rc
join customers c on c.customer_unique_id = rc.person
join orders o on o.customer_id = c.customer_id
join order_items i on i.order_id = o.order_id
join products p on p.product_id = i.product_id;
ALTER TABLE rfm_customers
  MODIFY person CHAR(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
SELECT COUNT(*) FROM rfm_customers;
SELECT COUNT(*) FROM order_items;
SELECT COUNT(*) FROM products;
SELECT COUNT(*) FROM rfm_customers rc
  JOIN customers c ON c.customer_unique_id = rc.person;