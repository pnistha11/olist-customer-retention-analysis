# Findings memo — skeleton

Fill the brackets with your real numbers, then tell me and I'll turn
this into a formatted one-page PDF.

---

## How to write this (read once, then delete this section)

**Your reader is a category manager.** They own a P&L, they're busy,
and they will read the first two lines and the last three. They do not
care that you used `NTILE` or a window function. They care about what
is losing money and what to do on Monday.

Five rules:

1. **Lead with the number, not the method.** Not "I performed cohort
   analysis and found that retention is low." Instead: "97 of every 100
   customers never buy again."
2. **Every finding needs a size.** A finding without R$ or % attached is
   an observation, not a finding.
3. **One page. Genuinely one page.** If it spills, cut the third-most
   interesting thing. Discipline about this is itself a signal.
4. **Recommendations must be actionable by the reader.** "Improve
   retention" is not an action. "Trigger a category-matched offer at day
   30 for the 12k customers who bought health & beauty once" is.
5. **Name one limitation.** Every real analysis has one. Stating it
   builds more trust than hiding it. Reviews firing on dispatch rather
   than delivery is a good honest candidate.

**On currency:** this is Brazilian data in **R$**. Don't relabel it ₹.
If you want a rupee figure for an Indian audience, write it as
"R$ X (approx. ₹Y at R$1 = ₹Z)" and state the rate you used. Quietly
swapping the symbol is the kind of thing that gets caught in an
interview and costs you the room.

---

## Customer behaviour review — Olist marketplace

**Period:** Aug 2026 – Sep 2026 | **Prepared by:** [Nistha Patel] | **Date:** [07-09-2026]

### What I found

- **[Retention finding.]** Of 94990 customers acquired in the period,
  only 3.04% ever placed a second order. Month-1 return rate averaged
  0.46% across cohorts and did not improve over 20 months of trading —
  this is structural, not seasonal.

- **[Funnel finding.]** 96% of placed orders reach delivery.
  The largest single loss is at Shipped, where 1,637 orders (1.6%) drop out.
  Median time from order to delivery is 10.2 days, but the slowest 10% of
  customers wait 23.1 days — 2.3x longer.

- **[Value concentration finding.]** The top 20% of customers by value
  generate 53.6% of revenue. Hibernating is the largest segment at 36,964
  customers (38.9%) and holds 38.1% of historic revenue — an average
  of 446 days since their last order.

### Why it matters

- At a 3.0% repeat rate, effectively all revenue must be bought through acquisition.
  Lifting repeat purchase from 3.0% to 6.0% — still far below marketplace norms —
  would generate roughly 2,850 additional orders, worth approximately
  R$ 457,000 per year at today's average order value of R$160.

- Customers whose first delivery arrived late repeat at 2.54% versus
  3.07% for on-time deliveries — a **0.53%** gap. Applied to 7,596
  late deliveries, that's about 40 customers — roughly R$6,450 in forgone second orders.

- The dormant Hibernating segment — 36,964 customers averaging 446 days
  since their last order — is worth R$ 6.0M in past revenue. Reactivating
  even 5% returns roughly R$ 296,000 in new orders, materially cheaper than
  acquiring 1,850 new customers.

### What I'd do about it

1. Launch a day-30 post-delivery offer to the 18,353 New Customers, matched
   to their first-purchase category. Median gap between first and second order
   is 29 days, so the window closes within a month of delivery. Run as a holdout
   test; success = 6% second-order rate within 60 days (double the current 3.0%).

2. Stop treating acquisition growth as growth. Monthly customer acquisition grew
   roughly 8× between January 2017 and July 2018 while the 3-month repeat rate stayed
   flat at ~1%. Every unit of growth was purchased; none compounded. Recommend tracking
   repeat rate as a headline metric alongside new customers, so the gap becomes
   visible monthly rather than annually.

3. Protect the 1,030 customers in "At Risk" and "Cannot Lose Them." They are
   only 1.1% of the base, but they are almost the only customers who buy more than once
   (average 2.0 and 3.1 orders versus 1.0 across every other segment). At 433
   and 443 days since last order, both groups are already lapsing.

### Method and limitations

Cohorts, funnel and RFM built in MySQL 8 over 99,441 orders from the Olist
public dataset, keyed on `customer_unique_id` (the order-level
`customer_id` is regenerated per order and would understate repeat
purchase to zero). Revenue is item price plus freight.

One caveat: review requests are sent at dispatch rather than delivery,
so "reviewed" is not strictly downstream of "delivered" — 2843 orders
carry a review without a recorded delivery date. The funnel above
enforces nesting, which slightly understates review volume.

---

## Numbers checklist

Run these before writing. If a bracket above is still empty, the number
comes from here:

| Number                                      | Source                                          |
| ------------------------------------------- | ----------------------------------------------- |
| Total customers, repeat %, repeat rate      | `02_cohort_retention.sql`, supporting query 1   |
| Average month-1 retention                   | `05_visuals.py` prints it                       |
| Median days between purchases               | `02_cohort_retention.sql`, supporting query 2   |
| Repeat rate: late vs on-time first delivery | `02_cohort_retention.sql`, supporting query 3   |
| Funnel counts and conversion                | `03_funnel.sql`, main query                     |
| Median and p90 stage durations              | `03_funnel.sql`, median block                   |
| GMV by status (leaked revenue)              | `03_funnel.sql`, money-leak query               |
| Segment sizes and revenue share             | `04_rfm.sql`, main query                        |
| Top-20% revenue concentration               | `04_rfm.sql`, Pareto query                      |
| Average order value                         | `SELECT AVG(order_revenue) FROM ...` — write it |
