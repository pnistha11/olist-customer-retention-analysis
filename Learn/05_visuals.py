"""
Olist Week 2 — visuals for the three analyses.

Reads straight from MySQL so there is one source of truth: the SQL.
Python only reshapes and draws. If a number looks wrong, fix the
query, not the chart.

Install:
    pip install pandas sqlalchemy pymysql matplotlib seaborn

Run:
    python 05_visuals.py

Outputs three PNGs next to this file, ready to drop into the memo.
"""

import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.ticker as mtick
import seaborn as sns
from sqlalchemy import create_engine
import os
PWD = os.environ.get("MYSQL_PWD", "")

# ---------------------------------------------------------------
# EDIT THIS LINE ONLY
USER, PWD, HOST, PORT, DB = "root", "", "localhost", 3306, "olist"
# ---------------------------------------------------------------

engine = create_engine(f"mysql+pymysql://{USER}:{PWD}@{HOST}:{PORT}/{DB}")

sns.set_theme(style="white")
plt.rcParams["figure.dpi"] = 130
plt.rcParams["font.size"] = 9


# ===============================================================
# 1. COHORT RETENTION HEATMAP
# ===============================================================
COHORT_SQL = """
WITH cust_orders AS (
    SELECT c.customer_unique_id AS person, o.order_purchase_timestamp AS ts
    FROM orders o JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled','unavailable')
      AND o.order_purchase_timestamp IS NOT NULL
),
stamped AS (
    SELECT person, ts, MIN(ts) OVER (PARTITION BY person) AS first_ts
    FROM cust_orders
),
indexed AS (
    SELECT person,
           CAST(DATE_FORMAT(first_ts,'%%Y-%%m-01') AS DATE) AS cohort_month,
           TIMESTAMPDIFF(MONTH,
               CAST(DATE_FORMAT(first_ts,'%%Y-%%m-01') AS DATE),
               CAST(DATE_FORMAT(ts,'%%Y-%%m-01') AS DATE)) AS month_index
    FROM stamped
),
cohort_size AS (
    SELECT cohort_month, COUNT(DISTINCT person) AS n_customers
    FROM indexed WHERE month_index = 0 GROUP BY cohort_month
),
activity AS (
    SELECT cohort_month, month_index, COUNT(DISTINCT person) AS n_active
    FROM indexed GROUP BY cohort_month, month_index
),
bounds AS (
    SELECT CAST(DATE_FORMAT(MAX(ts),'%%Y-%%m-01') AS DATE) AS last_month
    FROM cust_orders
)
SELECT a.cohort_month, s.n_customers AS cohort_size, a.month_index,
       100.0 * a.n_active / s.n_customers AS pct_retained,
       CASE WHEN DATE_ADD(a.cohort_month, INTERVAL a.month_index MONTH)
                 <= b.last_month THEN 1 ELSE 0 END AS is_observable
FROM activity a
JOIN cohort_size s ON s.cohort_month = a.cohort_month
CROSS JOIN bounds b
WHERE a.month_index BETWEEN 0 AND 12
  AND a.cohort_month BETWEEN '2017-01-01' AND '2018-08-01'
"""


def cohort_heatmap():
    df = pd.read_sql(COHORT_SQL, engine)

    # Hide cells that could not have happened yet. Painting them as
    # 0% would overstate churn — a very common chart error.
    df.loc[df["is_observable"] == 0, "pct_retained"] = None

    grid = df.pivot(index="cohort_month", columns="month_index",
                    values="pct_retained")
    sizes = (df[df["month_index"] == 0]
             .set_index("cohort_month")["cohort_size"])

    grid.index = [f"{d:%b %Y}  (n={sizes[d]:,})" for d in grid.index]

    # Month 0 is 100% by definition and would flatten the colour
    # scale, so scale on months 1+ only.
    scale_max = max(grid.loc[:, 1:].max().max(), 0.5)

    fig, ax = plt.subplots(figsize=(12, 7))
    sns.heatmap(
        grid, annot=True, fmt=".1f", vmin=0, vmax=scale_max,
        cmap="YlGnBu", linewidths=0.5, linecolor="white",
        cbar_kws={"label": "% of cohort active"},
        mask=grid.isna(), ax=ax,
    )
    ax.set_title(
        "Monthly retention by acquisition cohort\n"
        "Cells show % of the cohort placing an order that month. "
        "Blank = not yet observable.",
        loc="left", fontsize=11, pad=12,
    )
    ax.set_xlabel("Months since first purchase")
    ax.set_ylabel("")
    plt.tight_layout()
    plt.savefig("cohort_heatmap.png", bbox_inches="tight")
    plt.close()
    print("wrote cohort_heatmap.png")

    m1 = grid.loc[:, 1].mean()
    print(f"  average month-1 retention: {m1:.2f}%")


# ===============================================================
# 2. FUNNEL
# ===============================================================
FUNNEL_SQL = """
WITH base AS (
    SELECT o.order_id,
           o.order_purchase_timestamp      AS t_placed,
           o.order_approved_at             AS t_approved,
           o.order_delivered_carrier_date  AS t_shipped,
           o.order_delivered_customer_date AS t_delivered,
           r.t_reviewed
    FROM orders o
    LEFT JOIN (SELECT order_id, MIN(review_creation_date) AS t_reviewed
               FROM order_reviews WHERE review_creation_date IS NOT NULL
               GROUP BY order_id) r ON r.order_id = o.order_id
    WHERE o.order_purchase_timestamp IS NOT NULL
),
nested AS (
    SELECT 1 AS s_placed,
           (t_approved IS NOT NULL) AS s_approved,
           (t_approved IS NOT NULL AND t_shipped IS NOT NULL) AS s_shipped,
           (t_approved IS NOT NULL AND t_shipped IS NOT NULL
            AND t_delivered IS NOT NULL) AS s_delivered,
           (t_approved IS NOT NULL AND t_shipped IS NOT NULL
            AND t_delivered IS NOT NULL AND t_reviewed IS NOT NULL) AS s_reviewed
    FROM base
)
SELECT 1 AS step_no, 'Placed' AS stage, SUM(s_placed) AS orders FROM nested
UNION ALL SELECT 2,'Approved', SUM(s_approved)  FROM nested
UNION ALL SELECT 3,'Shipped',  SUM(s_shipped)   FROM nested
UNION ALL SELECT 4,'Delivered',SUM(s_delivered) FROM nested
UNION ALL SELECT 5,'Reviewed', SUM(s_reviewed)  FROM nested
ORDER BY step_no
"""


def funnel_chart():
    df = pd.read_sql(FUNNEL_SQL, engine)
    df["orders"] = df["orders"].astype(int)
    top = df["orders"].iloc[0]
    df["pct_of_placed"] = 100 * df["orders"] / top
    df["step_conv"] = 100 * df["orders"] / df["orders"].shift(1)
    df["dropped"] = df["orders"].shift(1) - df["orders"]

    fig, ax = plt.subplots(figsize=(9, 5))
    bars = ax.barh(df["stage"], df["orders"], color="#2a6f97", height=0.62)
    ax.invert_yaxis()

    for i, (bar, row) in enumerate(zip(bars, df.itertuples())):
        ax.text(bar.get_width() + top * 0.012, bar.get_y() + bar.get_height() / 2,
                f"{row.orders:,}  ({row.pct_of_placed:.1f}%)",
                va="center", fontsize=9)
        if i > 0 and pd.notna(row.dropped):
            ax.text(top * 0.02, bar.get_y() + bar.get_height() / 2,
                    f"-{int(row.dropped):,}  ({row.step_conv:.1f}% conv)",
                    va="center", fontsize=8, color="white", weight="bold")

    ax.set_xlim(0, top * 1.25)
    ax.set_xlabel("Orders")
    ax.set_title("Order funnel: placed to reviewed\n"
                 "White labels show loss and conversion at each step.",
                 loc="left", fontsize=11, pad=12)
    ax.xaxis.set_major_formatter(mtick.FuncFormatter(lambda x, _: f"{int(x):,}"))
    sns.despine(left=True)
    plt.tight_layout()
    plt.savefig("funnel.png", bbox_inches="tight")
    plt.close()
    print("wrote funnel.png")
    print(df[["stage", "orders", "pct_of_placed", "step_conv"]].to_string(index=False))


# ===============================================================
# 3. RFM SEGMENTS
#    Requires the rfm_customers table created by 04_rfm.sql.
# ===============================================================
def rfm_chart():
    df = pd.read_sql("""
        SELECT segment,
               COUNT(*)      AS customers,
               SUM(monetary) AS revenue
        FROM rfm_customers GROUP BY segment
    """, engine)

    df["pct_customers"] = 100 * df["customers"] / df["customers"].sum()
    df["pct_revenue"] = 100 * df["revenue"] / df["revenue"].sum()
    df = df.sort_values("pct_revenue", ascending=True)

    fig, ax = plt.subplots(figsize=(9, 5.5))
    y = range(len(df))
    ax.barh([i + 0.19 for i in y], df["pct_customers"], height=0.36,
            label="% of customers", color="#a8c6d9")
    ax.barh([i - 0.19 for i in y], df["pct_revenue"], height=0.36,
            label="% of revenue", color="#1b4965")
    ax.set_yticks(list(y))
    ax.set_yticklabels(df["segment"])
    ax.xaxis.set_major_formatter(mtick.PercentFormatter())
    ax.set_title("RFM segments: share of customers vs share of revenue\n"
                 "Bars that disagree are where the opportunity is.",
                 loc="left", fontsize=11, pad=12)
    ax.legend(frameon=False, loc="lower right")
    sns.despine(left=True)
    plt.tight_layout()
    plt.savefig("rfm_segments.png", bbox_inches="tight")
    plt.close()
    print("wrote rfm_segments.png")
    print(df.sort_values("pct_revenue", ascending=False).to_string(index=False))


if __name__ == "__main__":
    cohort_heatmap()
    funnel_chart()
    rfm_chart()
    print("\nDone. Numbers printed above go straight into the memo.")
