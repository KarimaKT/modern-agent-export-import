---
name: schema-definitions-and-dax
description: ContosoRetail dataset schema — table names, column types, and join patterns. And DAX patterns.
---
<!-- bic:source=blank -->
## ContosoRetail Schema

**Dataset type:** Power BI push dataset. No active relationships — use SUMX(FILTER()) for all cross-table joins.
**WorkspaceID:** f9b7b05b-44c8-4740-9372-b9a958007c63
**DatasetID:** 3edbaf84-2fe8-47d8-b4c8-97bd8d6c806b

## DAX patterns

DAX rules:
* Before aggregating an unfamiliar table, run EVALUATE TOPN(3, tablename) to discover columns and sample values.
* No active relationships — use SUMX(FILTER()) for all cross-table joins.
* Prefer SUMMARIZECOLUMNS for aggregations.
* Adaptive TOPN for row-level queries: estimate avg char width of each column your query selects from the schema probe. Set N = floor(100000 / estimated_row_width), clamped to [50, 400]. Default TOPN(200) when no probe available.
  If results appear incomplete, retry with halved N or aggregated query.
* For unknown cardinality, run EVALUATE ROW("rowcount", COUNTROWS(tablename)) before row-level fetch.
* On DAX error or implausible result, diagnose, rewrite, retry up to 3 times.

## Tables and key columns

### dim_customers
customer_id (PK), customer_name, customer_segment (New/Regular/VIP/At-Risk), email, region, signup_date, lifetime_value

### dim_products
product_id (PK), product_name, category (Electronics/Beauty/Apparel/Sports & Outdoors/Home & Garden), unit_cost, unit_price, margin_pct

### dim_stores
store_id (PK), store_name, region (North/South/East/West/Southwest/Midwest), store_type, manager_name

### dim_employees
employee_id (PK), employee_name, department, store_id (FK), performance_rating, quota_attainment

### fact_orders
order_id (PK), customer_id (FK), store_id (FK), order_date, order_value, channel (In-Store/Online/Mobile), region

### fact_order_items
order_item_id (PK), order_id (FK), product_id (FK), quantity, unit_price, discount_pct

### fact_returns
return_id (PK), order_item_id (FK), return_date, return_reason, customer_id (FK), product_id (FK)

### fact_inventory
inventory_id (PK), store_id (FK), product_id (FK), stock_level, reorder_point, stockout_flag, last_restocked

### fact_marketing_campaigns
campaign_id (PK), campaign_name, channel (Email/Social/Display), start_date, end_date, campaign_cost, revenue_lift, net_revenue_lift, roi

### fact_website_sessions
session_id (PK), customer_id (FK), session_date, pages_viewed, conversion_flag, channel

### fact_support_tickets
ticket_id (PK), customer_id (FK), open_date, close_date, issue_category, resolved_flag, campaign_id (FK)

### fact_supplier_performance
supplier_id (PK), supplier_name, product_id (FK), on_time_flag (Yes/No), quality_score, po_value

### fact_store_traffic
traffic_id (PK), store_id (FK), traffic_date, visitor_count, conversion_rate, day_of_week

## Join patterns (no active relationships)
All joins must be explicit. Use SUMX(FILTER()) pattern:
SUMX(FILTER(fact_orders, fact_orders[customer_id] = dim_customers[customer_id]), fact_orders[order_value])

## Schema exploration
To discover sample values and column widths for any table:
EVALUATE TOPN(3, tablename)
