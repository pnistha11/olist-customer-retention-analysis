'''
    Reads straight from MySQL so there is one source of truth: the SQL.
    Python only reshapes and draws. If a number looks wrong, fix the
    query, not the chart.
'''
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.ticker as mtick
import seaborn as sns
from sqlalchemy import create_engine


# db connection
USER, PWD, HOST, PORT, DB = 'root', 'niss1883', 'localhost', 3306, 'olist'

engine = create_engine(f'mysql+pymysql://{USER}:{PWD}@{HOST}:{PORT}/{DB}')

sns.set_theme(style='white')
plt.rcParams['figure.dpi'] = 130
plt.rcParams['font.size'] = 9

# -----------------------------------------------
# 1. Cohort retention heatmap
# -----------------------------------------------
COHORT_SQL = """
with cust_orders as (
    select c.customer_unique_id as person, o.order_purchase_timestamp as ts
    from orders o join customers c on c.customer_id = o.customer_id
    where o.order_status not in ('canceled', 'unavailable')
        and o.order_purchase_timestamp is not null
),
stamped as(
    select person, ts, min(ts) over (partition by person) as first_ts
    from cust_orders
),
indexed as (
    select person,
        cast(date_format(first_ts, '%%Y-%%m-01') as date) as cohort_month,
        timestampdiff(month,
            cast(date_format(first_ts, '%%Y-%%m-01') as date),
            cast(date_format(ts,'%%Y-%%m-01') as date)) as month_index
    from stamped
),
cohort_size as (
    select cohort_month, count(distinct person) as n_customers
    from indexed where month_index = 0 group by cohort_month
),
activity as (
    select cohort_month, month_index, count(distinct person) as n_active
    from indexed group by cohort_month, month_index
),
bounds as (
    select cast(date_format(max(ts),'%%Y-%%m-01') as date) as last_month
    from cust_orders
)
select a.cohort_month, s.n_customers as cohort_size, a.month_index,
    100.0 * a.n_active / s.n_customers as pct_retained,
    case when date_add(a.cohort_month, interval a.month_index month)
        <= b.last_month then 1 else 0 end as is_observable
from activity a
join cohort_size s on s.cohort_month = a.cohort_month
cross join bounds b
where a.month_index between 0 and 12
    and a.cohort_month between '2017-01-01' and '2018-08-01'
"""

def cohort_heatmap():
    df = pd.read_sql(COHORT_SQL, engine)

    # Hide cells that could not have happened yet. Painting them as
    # 0% would overstate churn — a very common chart error.
    df.loc[df['is_observable'] == 0, 'pct_retained'] = None

    grid = df.pivot(index ='cohort_month', columns = 'month_index',
                    values='pct_retained')
    sizes = (df[df['month_index'] == 0]
             .set_index('cohort_month')['cohort_size'])

    grid.index = [f'{d:%b %Y} (n={sizes[d]:,})' for d in grid.index]

    # Month 0 is 100% by definition and would flatten the colour
    # scale, so scale on months 1+ only.
    scale_max = max(grid.loc[:, 1:].max().max(), 0.5)

    fig, ax = plt.subplots(figsize=(12, 7))
    sns.heatmap(
        grid, annot=True, fmt='.1f', vmin=0, vmax=scale_max,
        cmap='YlGnBu', linewidths=0.5, linecolor='white',
        cbar_kws={'label': '% of cohort active'},
        mask=grid.isna(), ax=ax,
    )       
    ax.set_title(
        'Monthly retention by acqusition cohort\n'
        'Cells show % of the cohort placing an order that month.'
        'Blank = not yet observable.',
        loc='center', fontsize=11, pad=12,
    )
    ax.set_xlabel("Month since first purchase")
    ax.set_ylabel('')
    plt.tight_layout()
    plt.savefig('cohort_heat.png', bbox_inches='tight')
    plt.close()
    print('Wrote cohort_heatmap.png')

    m1 = grid.loc[:, 1].mean()
    print(f'    average month-1 retetion : {m1:.2f}%')


# -----------------------------------------------
# 2. Funnel
# -----------------------------------------------
FUNNEL_SQL = '''
with base as (
    select o.order_id,
           o.order_purchase_timestamp as t_placed,
           o.order_approved_at as t_approved,
           o.order_delivered_carrier_date as t_shipped,
           o.order_delivered_customer_date as t_delivered,
           r.t_reviewed
    from orders o
    left join (select order_id, min(review_creation_date) as t_reviewed
              from order_reviews where review_creation_date is not null
              group by order_id) r on r.order_id = o.order_id
    where o.order_purchase_timestamp is not null
),
nested as (
    select 1 as s_placed,
            (t_approved is not null) as s_approved,
            (t_approved is not null and t_shipped is not null) as s_shipped,
            (t_approved is not null and t_shipped is not null
                and t_delivered is not null) as s_delivered,
            (t_approved is not null and t_shipped is not null
                 and t_delivered is not null and t_reviewed is not null) as s_reviewed
    from base
)
select 1 as step_no, 'Placed' as stage, sum(s_placed) as orders from nested
union all select 2, 'Approved', sum(s_approved) from nested
union all select 3, 'Shipped', sum(s_shipped) from nested
union all select 4, 'Delivered' , sum(s_delivered) from nested
union all select 5, 'Reviewed', sum(s_reviewed) from nested
order by step_no
'''

def funnel_chart() :
    df = pd.read_sql(FUNNEL_SQL, engine)
    df['orders'] = df['orders'].astype(int)
    top = df['orders'].iloc[0]
    df['pct_of_placed'] = 100 * df['orders'] / top
    df['step_conv'] = 100 * df['orders'] / df['orders'].shift(1)
    df['dropped'] = df['orders'].shift(1) - df['orders']

    fig, ax = plt.subplots(figsize=(9, 5))
    bars = ax.barh(df['stage'], df['orders'], color='#2a6f97', height=0.62)
    ax.invert_yaxis()

    for i, (bar, row) in enumerate(zip(bars, df.itertuples())):
        ax.text(bar.get_width() + top * 0.012, bar.get_y() + bar.get_height() / 2,
                f'{row.orders:,} ({row.pct_of_placed:.1f}%)',
                va='center', fontsize=9)
        if i > 0 and pd.notna(row.dropped) :
                ax.text(top * 0.02, bar.get_y() + bar.get_height() / 2,
                    f'-{int(row.dropped) :,} ({row.step_conv:.1f}% conv)',
                    va = 'center', fontsize=8, color='white', weight='bold')

    ax.set_xlim(0, top * 1.25)
    ax.set_xlabel('Orders')
    ax.set_title('Order funnel : placed to reviewed\n'
                 'White labels show loss and conversion at each step.',
                 loc='center', fontsize=11, pad=12)

    ax.xaxis.set_major_formatter(mtick.FuncFormatter(lambda x, _: f'{int(x):,}'))
    sns.despine(left=True)
    plt.tight_layout()
    plt.savefig('funnel.png', bbox_inches='tight')
    plt.close()
    print('wrote funnel.png')
    print(df[['stage','orders', 'pct_of_placed', 'step_conv']].to_string(index=False))

# -----------------------------------------------
# 3. rfm segments
#    requires the rfm_customers table created by 04_rfm.sql.
# -----------------------------------------------
def rfm_chart():
     df = pd.read_sql('''
            select segment,
                count(*) as customers,
                sum(monetary) as revenue
            from rfm_customers group by segment
''', engine)
     df['pct_customers'] = 100 * df['customers'] / df['customers'].sum()
     df['pct_revenue'] = 100 * df['revenue'] / df['revenue'].sum()
     df = df.sort_values('pct_revenue', ascending=True)

     fig, ax = plt.subplots(figsize=(9, 5.5))
     y = range(len(df))
     ax.barh([i + 0.19 for i in y], df['pct_customers'], height=0.36,
             label='% of customers', color='#a8c6d9')
     ax.barh([i - 0.19 for i in y], df['pct_revenue'], height=0.36,
             label='% of revenue', color='#1b4965')
     ax.set_yticks(list(y))
     ax.set_yticklabels(df['segment'])
     ax.xaxis.set_major_formatter(mtick.PercentFormatter())
     ax.set_title('RFM segments : share of customers vs share of revenue\n'
                  'Bars that disagree are where the opportunity is.',
                  loc='center', fontsize=11, pad=12)
     ax.legend(frameon=False, loc='lower right')
     sns.despine(left=True)
     plt.tight_layout()
     plt.savefig('rfm_segments.png', bbox_inches='tight')
     plt.close()
     print('wrote rfm_segment.png')
     print(df.sort_values('pct_revenue', ascending=False).to_string(index=False))
     
if __name__ == "__main__":
    cohort_heatmap()
    funnel_chart()
    rfm_chart()
    print('\n Done. Numbers printed above go straight into the moemo.')