# Zomato Delivery Operations Analytics

**Why do 3 in 10 food deliveries arrive late — and which fix should the business fund first?**

A SQL-only analytics project on 45,584 real delivery records across 22 Indian cities. Raw CSV → normalised star schema → 20 business questions → a costed, ranked recommendation — all in PostgreSQL.



## The problem

Zomato promises delivery in roughly 30 minutes. **29.8% of orders miss that window.** The operations team's instinct is *"our riders are too slow — train them."* This project tests that assumption against the data instead of assuming it, using nothing but SQL.

## Key findings

| Finding | Number |
|---|---|
| Orders analysed | 45,584 |
| SLA breach rate | 29.8% |
| Jam traffic vs. Low traffic breach rate | 50.6% vs 7.9% (6.4× worse) |
| Breach rate once distance exceeds ~10 km | Flattens at ~45% (a threshold, not a slope) |
| Breach rate with 2+ orders batched per trip | 99.9–100% |
| Breach rate by city | Narrow 28.6–33.0% band — no single "problem city" |
| Vehicle condition 0 (poor) vs. 1/2 (fair/good) | 41.7% vs ~24% |

## The recommendation

Four candidate fixes were modelled as **counterfactuals** in SQL — for each, every affected order was re-scored under the proposed change and re-tested against the SLA — and ranked by how many of the 13,597 real late orders each would have rescued.

| Rank | Programme | % of all breaches removed |
|---|---|---|
| 1 | Fleet maintenance (fix condition-0 vehicles) | **15.0%** |
| 2 | Cap batching at 1 order per trip | **13.2%** |
| 3 | Coach below-median delivery partners | 3.7% |
| 4 | 45-min SLA on festival dates | 3.5% |

**The intuitive fix — "coach the slow riders" — ranks third.** Fleet maintenance and a batching cap each outperform it, for far less organisational effort.

---

## Repository structure

```
zomato-delivery-ops-analytics/
├── README.md
├── sql/
│   ├── 01_schema.sql               # star schema: staging, core, mart
│   ├── 02_cleaning.sql             # load, profile, repair, normalise
│   ├── 03_analysis_queries.sql     # 20 business questions
│   └── 04_views.sql                # BI-facing view layer
├── data/
│   ├── Zomato_Dataset.csv          # raw source (45,584 rows)
│   └── query-results/              # exported aggregates used by the dashboard
├── dashboard/
│   └── index.html                  # standalone interactive dashboard (no dependencies)
└── docs/
    └── presentation-deck.pdf
```

## Tech stack

- **PostgreSQL** — schema design, data cleaning, analysis, views
- **SQL techniques**: window functions (`RANK`, `NTILE`, `LAG`), CTEs, `PERCENTILE_CONT`, `MODE() WITHIN GROUP`, custom PL/pgSQL functions, materialized views, counterfactual scenario modelling
- **Vanilla JavaScript + SVG** — the interactive dashboard (zero external libraries, works offline)

## How to run

```bash
createdb zomato_ops
psql -d zomato_ops -f sql/01_schema.sql
cd data && psql -d zomato_ops -f ../sql/02_cleaning.sql && cd ..
psql -d zomato_ops -f sql/03_analysis_queries.sql
psql -d zomato_ops -f sql/04_views.sql
```

Then open `dashboard/index.html` in any browser — no server or build step required.

## Data quality

The raw file contained 11 distinct data-quality defects — three incompatible time formats in one column, ~8% of rows with GPS coordinates recorded as (0,0), sign-flipped coordinates, out-of-range ages and ratings. Every defect was profiled, logged to an auditable table, and repaired without silently dropping rows. See `sql/02_cleaning.sql` for the full repair logic.

## Limitations

- No revenue/order-value column in the source data — impact is measured in minutes lost, not currency.
- ~8% of orders have unusable GPS data on both endpoints; distance-based findings run on the remaining ~92%.
- The dataset spans 8 weeks — enough to establish daily and hourly patterns, too short for seasonal trends.
- The 30-minute SLA used throughout is an analyst-set benchmark, externalised into a `sla_policy` table, not a published Zomato commitment.
