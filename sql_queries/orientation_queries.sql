-- what date range am I actually working with?!
select min(order_purchase_timestamp) as first_order,
	   max(order_purchase_timestamp) as last_order
from orders;
/*Note that Sep-Dec 2016 is nearly
empty (a handful of orders) and Oct 2018 is a partial month.
That is why the cohort script clips to 2017-01 .. 2018-08.  */

-- what statues exists ,and how common are they?
select order_status, count(*) n,
	   round(100 * count(*) / sum(count(*)) over (), 2) pct
from orders group by order_status order by n desc;
/* 'delivered' dominates. Notice how few orders sit in 'approved' —
that's why the funnel uses timestamps, not statuses. */

-- the big one : proving that customer_id is per-order.
select count(*) as customer_rows,
	   count(distinct customer_id) as distinct_customer_id,
       count(distinct customer_unique_id) as distinct_people
from customers;
-- customer_id is unique per row 99441. real people ~96096.

-- How many people ever bought more than once?
select orders_per_person, count(*) as people
from (
	select c.customer_unique_id, count(*) as orders_per_person
    from orders o
    join customers c on c.customer_id = o.customer_id
    group by c.customer_unique_id    
) x
group by orders_per_person
order by orders_per_person;
-- ~97% bought exactly once. Sit with this number — it drives every conclusion in memo.