#!/usr/bin/env python3
"""
Convert the nursery workbook (Stock_Details.xlsx / "Stock Details.xlsx") into CSV
files for loading into Salesforce with the Bulk API 2.0 (`sf data upsert bulk` /
`sf data import bulk`).

Outputs (in --out-dir, default ./data):
  Plants.csv           Name, Plant_Key__c
  Plant_Purchases.csv  from table PlantPurchases  (columns A-F and H; G is calculated)
  Plant_Sales.csv      from table DailyStockSales (columns A-D and J; E-I are calculated)

Rows with a missing date, quantity, price or plant name are NOT written; they are
listed on screen so you can fix them in Excel and re-run.

Usage:
  pip install openpyxl
  python scripts/excel_to_csv.py "Requirements/Stock Details.xlsx" --out-dir data
"""
import argparse
import csv
import datetime as dt
import os
import sys
from decimal import Decimal, InvalidOperation

try:
    import openpyxl
except ImportError:  # pragma: no cover
    sys.exit("openpyxl is required: pip install openpyxl")

PURCHASE_TABLE = "PlantPurchases"
SALES_TABLE = "DailyStockSales"

# Excel header -> Salesforce field, in output column order.
PURCHASE_COLUMNS = [
    ("Purchase Date", "Purchase_Date__c"),
    ("Plant / Item", "Plant__r.Plant_Key__c"),
    ("Variety / Size", "Variety_Size__c"),
    ("Supplier", "Supplier__c"),
    ("Quantity Purchased", "Quantity_Purchased__c"),
    ("Purchase Price", "Purchase_Price__c"),
    ("Notes", "Notes__c"),
]
SALES_COLUMNS = [
    ("Sale Date", "Sale_Date__c"),
    ("Plant / Item", "Plant__r.Plant_Key__c"),
    ("Quantity Sold", "Quantity_Sold__c"),
    ("Selling Price", "Selling_Price__c"),
    ("Notes", "Notes__c"),
]
DATE_FORMATS = ("%Y-%m-%d", "%d-%m-%Y", "%d/%m/%Y", "%d.%m.%Y", "%d-%b-%Y", "%d %b %Y", "%m/%d/%Y")


def normalise_name(value):
    """Trim and collapse whitespace - must match PlantTriggerHandler.normaliseName."""
    if value is None:
        return ""
    return " ".join(str(value).split())


def plant_key(name):
    """Must match PlantTriggerHandler.toKey."""
    return normalise_name(name).lower()


def to_date(value):
    if value is None or (isinstance(value, str) and not value.strip()):
        return None
    if isinstance(value, dt.datetime):
        return value.date()
    if isinstance(value, dt.date):
        return value
    text = str(value).strip()
    for fmt in DATE_FORMATS:
        try:
            return dt.datetime.strptime(text, fmt).date()
        except ValueError:
            continue
    return None


def to_decimal(value):
    if value is None or (isinstance(value, str) and not value.strip()):
        return None
    try:
        return Decimal(str(value).replace(",", "").strip())
    except InvalidOperation:
        return None


def number_text(value):
    """Plain decimal text without exponent or trailing zeros (e.g. 12.5, 10)."""
    text = format(value.normalize(), "f")
    return text


def find_table(workbook, table_name):
    for sheet in workbook.worksheets:
        if table_name in sheet.tables:
            return sheet, sheet.tables[table_name].ref
    sys.exit(f"Table '{table_name}' not found in the workbook.")


def read_table(workbook, table_name):
    """Yield (excel_row_number, {header: value}) for each data row of an Excel table."""
    sheet, ref = find_table(workbook, table_name)
    rows = list(sheet[ref])
    headers = [normalise_name(cell.value) for cell in rows[0]]
    for row in rows[1:]:
        values = {headers[i]: cell.value for i, cell in enumerate(row)}
        yield row[0].row, sheet.title, values


def is_blank_row(values, headers):
    return all(
        values.get(h) is None or (isinstance(values.get(h), str) and not values.get(h).strip())
        for h in headers
    )


def convert(table_rows, columns, date_header, qty_header, price_header, label, problems):
    """Validate rows and return list of output dicts keyed by Salesforce field."""
    input_headers = [excel for excel, _ in columns]
    output = []
    for row_number, sheet_title, values in table_rows:
        if is_blank_row(values, input_headers):
            continue
        where = f"{sheet_title} row {row_number}"
        issues = []

        name = normalise_name(values.get("Plant / Item"))
        if not name:
            issues.append("missing Plant / Item")
        date_value = to_date(values.get(date_header))
        if date_value is None:
            issues.append(f"missing or invalid {date_header}")
        elif date_value > dt.date.today() + dt.timedelta(days=1):
            # Same check as the Date_Not_In_Future validation rule in Salesforce.
            issues.append(f"{date_header} {date_value.isoformat()} is in the future (year typo?)")
        qty = to_decimal(values.get(qty_header))
        if qty is None or qty <= 0 or qty != qty.to_integral_value():
            issues.append(f"{qty_header} must be a whole number > 0 (got {values.get(qty_header)!r})")
        price = to_decimal(values.get(price_header))
        if price is None or price < 0:
            issues.append(f"{price_header} must be a number >= 0 (got {values.get(price_header)!r})")

        if issues:
            problems.append(f"[{label}] {where}: " + "; ".join(issues))
            continue

        record = {}
        for excel_header, field in columns:
            raw = values.get(excel_header)
            if field == "Plant__r.Plant_Key__c":
                record[field] = plant_key(name)
                record["_name"] = name
            elif excel_header == date_header:
                record[field] = date_value.isoformat()
            elif excel_header == qty_header:
                record[field] = number_text(qty)
            elif excel_header == price_header:
                record[field] = number_text(price)
            else:
                record[field] = "" if raw is None else str(raw).strip()
        output.append(record)
    return output


def write_csv(path, fieldnames, records):
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore", lineterminator="\n")
        writer.writeheader()
        writer.writerows(records)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("workbook", help="Path to Stock_Details.xlsx")
    parser.add_argument("--out-dir", default="data", help="Folder for the CSV files (default: data)")
    args = parser.parse_args()

    workbook = openpyxl.load_workbook(args.workbook, data_only=True)
    problems = []

    purchases = convert(
        read_table(workbook, PURCHASE_TABLE), PURCHASE_COLUMNS,
        "Purchase Date", "Quantity Purchased", "Purchase Price", "Purchases", problems,
    )
    sales = convert(
        read_table(workbook, SALES_TABLE), SALES_COLUMNS,
        "Sale Date", "Quantity Sold", "Selling Price", "Sales", problems,
    )

    # Distinct plants from both sheets; first spelling seen wins for the display name.
    plants = {}
    for record in purchases + sales:
        plants.setdefault(record["Plant__r.Plant_Key__c"], record["_name"])

    purchased_keys = {r["Plant__r.Plant_Key__c"] for r in purchases}
    warnings = sorted(
        {f"[Sales] '{r['_name']}' is sold but never purchased - it will show CHECK: oversold"
         for r in sales if r["Plant__r.Plant_Key__c"] not in purchased_keys}
    )

    os.makedirs(args.out_dir, exist_ok=True)
    write_csv(
        os.path.join(args.out_dir, "Plants.csv"),
        ["Name", "Plant_Key__c"],
        [{"Name": name, "Plant_Key__c": key} for key, name in sorted(plants.items())],
    )
    write_csv(os.path.join(args.out_dir, "Plant_Purchases.csv"), [f for _, f in PURCHASE_COLUMNS], purchases)
    # Oldest first so Stock After Sale is calculated in date order when loaded.
    sales.sort(key=lambda r: r["Sale_Date__c"])
    write_csv(os.path.join(args.out_dir, "Plant_Sales.csv"), [f for _, f in SALES_COLUMNS], sales)

    print(f"Plants.csv:          {len(plants)} plants")
    print(f"Plant_Purchases.csv: {len(purchases)} purchases")
    print(f"Plant_Sales.csv:     {len(sales)} sales")
    if warnings:
        print("\nWarnings (rows still written):")
        for line in warnings:
            print("  " + line)
    if problems:
        print(f"\n{len(problems)} row(s) NOT written - fix them in Excel and re-run:")
        for line in problems:
            print("  " + line)
        return 1
    print("\nAll rows converted.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
