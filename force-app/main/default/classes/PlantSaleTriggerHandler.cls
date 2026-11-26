/**
 * Logic for PlantSaleTrigger.
 *
 * Before insert / before update (when quantity or plant changed):
 *  1. Query the related plants once for Stock_Remaining__c and Avg_Purchase_Price__c.
 *  2. Oversell check: quantities in the batch are consumed per plant in Sale Date
 *     order (for updates the old quantity is added back first). A sale that needs
 *     more than the available stock is blocked, unless the user has the
 *     Allow_Oversell custom permission.
 *  3. Unit_Cost__c = plant's Avg Purchase Price (on insert, or on update when the
 *     quantity changed and Unit_Cost__c is blank) - a snapshot, so later purchases
 *     do not change past profit.
 *  4. Cost_of_Plants_Sold__c = Quantity_Sold__c * Unit_Cost__c.
 *  5. Stock_After_Sale__c = running stock after this sale.
 *
 * The plant query uses WITH SYSTEM_MODE (API 67+ defaults to user mode): stock and
 * cost must be read even by users who cannot see those fields. Record sharing still
 * follows the class's "with sharing".
 */
public with sharing class PlantSaleTriggerHandler {
    public static final String ALLOW_OVERSELL_PERMISSION = 'Allow_Oversell';

    /** True when the running user holds the Allow_Oversell custom permission. */
    public static Boolean canOversell() {
        return FeatureManagement.checkPermission(ALLOW_OVERSELL_PERMISSION);
    }

    public static void beforeInsert(List<Plant_Sale__c> newSales) {
        processSales(newSales, null);
    }

    public static void beforeUpdate(List<Plant_Sale__c> newSales, Map<Id, Plant_Sale__c> oldMap) {
        List<Plant_Sale__c> changed = new List<Plant_Sale__c>();
        for (Plant_Sale__c sale : newSales) {
            Plant_Sale__c oldSale = oldMap.get(sale.Id);
            if (sale.Quantity_Sold__c != oldSale.Quantity_Sold__c || sale.Plant__c != oldSale.Plant__c) {
                changed.add(sale);
            }
        }
        if (!changed.isEmpty()) {
            processSales(changed, oldMap);
        }
    }

    /** Roll-up summaries already reverse the stock; kept for future use. */
    public static void afterDelete(List<Plant_Sale__c> oldSales) {
        return;
    }

    /** Roll-up summaries already restore the stock; kept for future use. */
    public static void afterUndelete(List<Plant_Sale__c> restoredSales) {
        return;
    }

    private static void processSales(List<Plant_Sale__c> sales, Map<Id, Plant_Sale__c> oldMap) {
        Boolean isInsert = oldMap == null;

        Set<Id> plantIds = new Set<Id>();
        for (Plant_Sale__c sale : sales) {
            if (sale.Plant__c != null) {
                plantIds.add(sale.Plant__c);
            }
        }
        if (plantIds.isEmpty()) {
            return;
        }

        Map<Id, Plant__c> plantsById = new Map<Id, Plant__c>(
            [
                SELECT Id, Name, Stock_Remaining__c, Avg_Purchase_Price__c
                FROM Plant__c
                WHERE Id IN :plantIds
                WITH SYSTEM_MODE
            ]
        );

        // Available stock per plant. Stock_Remaining__c already includes the old
        // quantity of records being updated, so add it back before re-consuming.
        Map<Id, Decimal> availableByPlant = new Map<Id, Decimal>();
        for (Plant__c plant : plantsById.values()) {
            availableByPlant.put(plant.Id, nz(plant.Stock_Remaining__c));
        }
        if (!isInsert) {
            for (Plant_Sale__c sale : sales) {
                Plant_Sale__c oldSale = oldMap.get(sale.Id);
                if (oldSale.Plant__c == sale.Plant__c && availableByPlant.containsKey(sale.Plant__c)) {
                    availableByPlant.put(
                        sale.Plant__c,
                        availableByPlant.get(sale.Plant__c) + nz(oldSale.Quantity_Sold__c)
                    );
                }
            }
        }

        Boolean allowOversell = canOversell();

        for (SaleInOrder entry : sortBySaleDate(sales)) {
            Plant_Sale__c sale = entry.sale;
            Plant__c plant = plantsById.get(sale.Plant__c);
            if (plant == null) {
                continue;
            }

            Decimal quantity = nz(sale.Quantity_Sold__c);
            Decimal available = availableByPlant.get(plant.Id);

            if (quantity > available && !allowOversell) {
                sale.Quantity_Sold__c.addError(
                    'Only ' + Math.max(available, Decimal.valueOf(0)).format() +' units of ' + plant.Name + ' are in stock.'
                );
                continue;
            }

            Decimal stockAfter = available - quantity;
            availableByPlant.put(plant.Id, stockAfter);
            sale.Stock_After_Sale__c = stockAfter;

            if (isInsert || sale.Unit_Cost__c == null) {
                sale.Unit_Cost__c = nz(plant.Avg_Purchase_Price__c).setScale(2, System.RoundingMode.HALF_UP);
            }
            sale.Cost_of_Plants_Sold__c = (quantity * sale.Unit_Cost__c).setScale(2, System.RoundingMode.HALF_UP);
        }
    }

    /** Stable sort: by Sale Date (blank dates last), then original position. */
    private static List<SaleInOrder> sortBySaleDate(List<Plant_Sale__c> sales) {
        List<SaleInOrder> ordered = new List<SaleInOrder>();
        for (Integer i = 0; i < sales.size(); i++) {
            ordered.add(new SaleInOrder(sales[i], i));
        }
        ordered.sort();
        return ordered;
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }

    private class SaleInOrder implements Comparable {
        final Plant_Sale__c sale;
        final Integer position;

        SaleInOrder(Plant_Sale__c sale, Integer position) {
            this.sale = sale;
            this.position = position;
        }

        public Integer compareTo(Object other) {
            SaleInOrder that = (SaleInOrder) other;
            Date mine = sale.Sale_Date__c;
            Date theirs = that.sale.Sale_Date__c;
            if (mine != theirs) {
                if (mine == null) {
                    return 1;
                }
                if (theirs == null) {
                    return -1;
                }
                return mine < theirs ? -1 : 1;
            }
            return position - that.position;
        }
    }
}
