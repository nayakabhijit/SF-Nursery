# Nursery Stock & Sales — Salesforce App

A Salesforce DX project for a plant nursery's stock inventory and sales. It replaces the
`Stock_Details.xlsx` workbook (see `Requirements/`) with three custom objects, roll-ups and
formulas that reproduce the Excel logic, Apex triggers that block overselling, a
Lightning app (desktop + mobile), reports and a dashboard.

- API version: **68.0**
- Default org alias used below: **`goapps`** (replace with your own alias)

## Contents

| Area | What's included |
|---|---|
| Objects | `Plant__c` (master), `Plant_Purchase__c`, `Plant_Sale__c` (both master-detail to Plant); `Expense__c` (master), `Expense_Entry__c` (master-detail to Expense) |
| Apex | `PlantTrigger`, `PlantPurchaseTrigger`, `PlantSaleTrigger`, `ExpenseEntryTrigger` + handlers; `ProfitSummaryController`; `TestDataFactory` and test classes |
| Validation rules | Quantity > 0, price ≥ 0, expense amount > 0, date no more than 1 day in the future, plant cannot change on a sale |
| UI | Page layouts, compact layouts, Plant Lightning record page with stock banners, quick actions *New Purchase* / *New Sale* / *Add Expense*, tabs, **Nursery Stock** app, list views, **Profit & Loss** component on the Nursery Home page |
| Reports | Report types *Plants*, *Plants with Purchases*, *Plants with Sales*, *Expenses with Entries*; folder **Nursery Reports** with 6 reports; **Nursery Monthly Dashboard** |
| Security | Custom permissions `Allow_Oversell` and `View_Profit_and_Loss`; permission sets **Nursery Admin** and **Nursery Staff** |
| Data migration | `scripts/excel_to_csv.py` → `data/*.csv` |

## 1. Setup

1. Install the [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) and authorise your org:
   ```powershell
   sf org login web --alias goapps --set-default
   ```
2. **Currency (INR):** currency fields show the org's currency. If your org is not in INR yet,
   go to **Setup → Company Information → Edit → Currency Locale → English (India) – INR**.
   This cannot be set through metadata. Do it **before** you load any data.
3. **Dashboard running user:** `Nursery_Monthly_Dashboard` runs as `abhijit@agentforce.com`.
   For another org, change `<runningUser>` in
   `force-app/main/default/dashboards/Nursery_Dashboards/Nursery_Monthly_Dashboard.dashboard-meta.xml`.

## 2. Deploy

Validate first (dry run, runs all local tests, changes nothing):

```powershell
sf project deploy validate --manifest manifest/package.xml --test-level RunLocalTests --target-org goapps
```

Deploy:

```powershell
sf project deploy start --manifest manifest/package.xml --test-level RunLocalTests --target-org goapps
```

Run the tests on their own with coverage:

```powershell
sf apex run test --class-names PlantTriggerHandlerTest --class-names PlantPurchaseTriggerHandlerTest --class-names PlantSaleTriggerHandlerTest --code-coverage --result-format human --wait 10 --target-org goapps
```

If you add or remove files, regenerate the manifest:
`sf project generate manifest --source-dir force-app --output-dir manifest --name package.xml`

## 3. Assign permission sets

New fields are **not** visible to any profile (not even System Administrator) until a permission
set is assigned. Assign **Nursery Admin** to managers (and to yourself), **Nursery Staff** to counter staff:

```powershell
sf org assign permset --name Nursery_Admin --target-org goapps
sf org assign permset --name Nursery_Staff --on-behalf-of staff.user@example.com --target-org goapps
```

| Permission set | Plants | Purchases & Sales | Expenses | Expense Entries | Allow Oversell | Profit & Loss |
|---|---|---|---|---|---|---|
| Nursery Admin | Create / Read / Edit / Delete, View All, Modify All | Create / Read / Edit / Delete, View All, Modify All | Full | Full | Yes | Yes |
| Nursery Staff | Read | Create / Read / Edit (no delete) | Read | Create / Read / Edit (no delete) | No | No |

- Calculated fields (roll-ups, formulas and the trigger-set Unit Cost, Cost of Plants Sold and Stock After Sale) are read-only for everyone.
- Plant sharing is **Public Read Only**. Purchases and sales are *Controlled by Parent*, with the
  master-detail set so **Read** access to the Plant is enough to add purchases and sales.
- Share the **Nursery Reports** and **Nursery Dashboards** folders with staff from the Reports tab if they need them.

After deploying, open **App Launcher → Nursery Stock**. The Plant record page is activated as the
org default. If a layout does not show, check **Object Manager → (object) → Page Layouts → Page Layout Assignment**.

## 4. Load data from Excel

### 4.1 Convert the workbook to CSV

Needs Python 3 and openpyxl (`winget install Python.Python.3.12`, then `pip install openpyxl`).

```powershell
python scripts/excel_to_csv.py "Requirements/Stock Details.xlsx" --out-dir data
```

This writes `data/Plants.csv`, `data/Plant_Purchases.csv` and `data/Plant_Sales.csv`.
Blank rows are skipped. Rows with a missing or invalid date, quantity, price or plant name are **not**
written; the script lists them so you can fix them in Excel and run it again. Sales for a plant that
was never purchased are flagged as warnings.

### 4.2 Load in order: Plants → Purchases → Sales

The user who loads the data must have **Nursery Admin**, because historical sales may exceed the stock
recorded at the time. Without `Allow_Oversell` those rows would be rejected.

```powershell
sf data upsert bulk --sobject Plant__c --file data/Plants.csv --external-id Plant_Key__c --wait 10 --target-org goapps
sf data import bulk --sobject Plant_Purchase__c --file data/Plant_Purchases.csv --wait 10 --target-org goapps
sf data import bulk --sobject Plant_Sale__c --file data/Plant_Sales.csv --wait 10 --target-org goapps
```

- Plants are **upserted** on `Plant_Key__c`, so you can re-run that step safely.
- Purchases and sales have no natural unique key, so they are **inserted** (`import bulk`). The
  `Plant__r.Plant_Key__c` column links each one to its plant. **Do not run these two steps twice**,
  or you will get duplicates. To start again, delete the records first.
- Sales are sorted oldest first. Each sale's *Purchase Price (Avg Cost)* is the plant's average
  purchase price **at load time**, which is the same all-time average the Excel sheet used.

## 5. How the logic works

| Rule | Where |
|---|---|
| Purchase Cost = Qty × Price | Formula `Plant_Purchase__c.Purchase_Cost__c` |
| Purchased Qty, Total Purchase Cost, Sold Qty, Sales Revenue, Total COGS | Roll-up summaries on `Plant__c` |
| Avg Purchase Price = Total Purchase Cost ÷ Purchased Qty | Formula on `Plant__c` |
| Stock Remaining = Purchased − Sold; Stock Value; Avg Selling Price; Gross Profit; Stock Status | Formulas on `Plant__c` |
| Sale Revenue = Qty × Selling Price; Gross Profit | Formulas on `Plant_Sale__c` |
| Unit Cost (snapshot of Avg Purchase Price), Cost of Plants Sold, Stock After Sale | Set by `PlantSaleTriggerHandler` |
| Block overselling (unless `Allow_Oversell`) | `PlantSaleTriggerHandler` |
| Block deleting a purchase that would make stock negative (unless `Allow_Oversell`) | `PlantPurchaseTriggerHandler` |
| Normalise plant names, set `Plant_Key__c`, block duplicates | `PlantTriggerHandler` |

**Why Unit Cost is a snapshot:** if it were a live formula, a new purchase at a different price would
change the profit on every past sale. Editing a sale's quantity keeps its original unit cost.

**Apex access mode:** from API 67.0, Apex runs DML and SOQL in *user mode* by default. The handlers read
plant stock `WITH SYSTEM_MODE`, so the oversell check works for every user. Record sharing still
follows the classes' `with sharing`.

**Stock Status values:** `CHECK: oversold` (< 0), `Out of stock` (= 0), `Low stock` (≤ Reorder Level,
default 5), `In stock`. *Low stock* is new; the Excel sheet only had the other three.

### Expenses and net profit

1. **Expenses tab:** create one Expense per running cost, with its **Expense Name**, **Category**
   (Rent, Salaries & Wages, Utilities, Transport & Fuel, …) and **Type**:
   - **Daily** (tea, transport, labour by the day): add any number of entries per day.
   - **Monthly** (rent, salaries, electricity bill): one entry per month. Pick any day in the month and
     it is saved as the 1st. A second entry for the same month is blocked.
2. **Add Expense** on the Expense record (or **New** on the Expense Entries tab) records the amount
   and date. Untick **Active** on an Expense to stop new entries and keep its history.
3. **Nursery Home → Profit & Loss** (Nursery Admin only) shows, for the chosen year:

   | Figure | Calculation |
   |---|---|
   | Sales | Sum of Plant Sale `Sale_Revenue__c` |
   | Gross Profit | Sales − Cost of Plants Sold (Plant Sale `Gross_Profit__c`) |
   | Expenses | Sum of Expense Entry `Amount__c` |
   | **Net Profit** | Gross Profit − Expenses |
   | Net Margin | Net Profit ÷ Sales |

   It also shows this month's figures, a month-by-month table and expenses by category.

Standard Salesforce dashboards cannot subtract one report from another, so net profit is calculated
by `ProfitSummaryController` and shown by the `profitSummary` component. The **Nursery Monthly
Dashboard** shows expense totals (*Expenses*, *Expenses by Month*, *Expenses by Category*), from the
reports **Monthly Expenses** and **Expenses by Category**. Sales for one year are summed in Apex (SOQL
cannot `SUM` formula fields), which supports up to about 50,000 sales a year.

## 6. Excel → Salesforce mapping

### Plant Purchases (table `PlantPurchases`) → `Plant_Purchase__c`

| Col | Excel header | Salesforce field |
|---|---|---|
| A | Purchase Date | `Purchase_Date__c` |
| B | Plant / Item | `Plant__c` (master-detail; CSV column `Plant__r.Plant_Key__c`) |
| C | Variety / Size | `Variety_Size__c` |
| D | Supplier | `Supplier__c` |
| E | Quantity Purchased | `Quantity_Purchased__c` |
| F | Purchase Price | `Purchase_Price__c` |
| G | Purchase Cost | `Purchase_Cost__c` (formula, not loaded) |
| H | Notes | `Notes__c` |

### Daily Sell (table `DailyStockSales`) → `Plant_Sale__c`

| Col | Excel header | Salesforce field |
|---|---|---|
| A | Sale Date | `Sale_Date__c` |
| B | Plant / Item | `Plant__c` (master-detail; CSV column `Plant__r.Plant_Key__c`) |
| C | Quantity Sold | `Quantity_Sold__c` |
| D | Selling Price | `Selling_Price__c` |
| E | Purchase Price (avg cost) | `Unit_Cost__c` (set by trigger) |
| F | Sale Revenue | `Sale_Revenue__c` (formula) |
| G | Current Stock | `Current_Stock__c` (formula, live) and `Stock_After_Sale__c` (snapshot, set by trigger) |
| H | Stock Check | `Stock_Check__c` (formula) |
| I | Cost of Plants Sold | `Cost_of_Plants_Sold__c` (set by trigger) |
| J | Notes | `Notes__c` |

### Stock & Sales → `Plant__c`

| Col | Excel header | Salesforce field |
|---|---|---|
| A | Plant / Item | `Name` (+ `Plant_Key__c`) |
| B | Purchased Qty | `Purchased_Qty__c` |
| C | Sold Qty | `Sold_Qty__c` |
| D | Stock Remaining | `Stock_Remaining__c` |
| E | Avg Purchase Price | `Avg_Purchase_Price__c` |
| F | Stock Value | `Stock_Value__c` |
| G | Sales Revenue | `Sales_Revenue__c` |
| H | Avg Selling Price | `Avg_Selling_Price__c` |
| I | Stock Status | `Stock_Status__c` |

New fields with no Excel column: `Category__c`, `Reorder_Level__c`, `Total_Purchase_Cost__c`, `Total_COGS__c`, `Gross_Profit__c`.

### Monthly Dashboard → Reports & dashboard

| Excel | Salesforce |
|---|---|
| Month, Sales Amount, Cost of Plants Sold, Gross Profit, Gross Margin, Units Sold | Report **Monthly Sales & Profit** (current year, by calendar month; *Gross Margin %* summary formula) |
| Purchase Amount | Report **Monthly Purchases** (all time, by calendar month) |
| KPI: All-time Purchases | Dashboard metric (Monthly Purchases grand total) |
| KPI: Sales Amount, Gross Profit, Gross Margin | Dashboard metrics (Monthly Sales & Profit, current year) |
| Monthly chart | Dashboard column chart *Sales vs Cost by Month* and line chart *Units Sold by Month* |
| — | Reports **Stock Summary** and **Low / Out of Stock**, plus a dashboard table of low / out-of-stock plants |

### Entry Lists

Not needed: the Plant lookup replaces the plant dropdown, and date fields replace the date helper list.
