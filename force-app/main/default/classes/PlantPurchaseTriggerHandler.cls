/**
 * Logic for PlantPurchaseTrigger.
 *  - Blocks deleting a purchase if it would leave the plant with negative stock,
 *    unless the running user has the Allow_Oversell custom permission.
 *    Several purchases of the same plant deleted together are counted cumulatively.
 */
public with sharing class PlantPurchaseTriggerHandler {
    public static void beforeDelete(List<Plant_Purchase__c> oldPurchases) {
        if (PlantSaleTriggerHandler.canOversell()) {
            return;
        }

        Set<Id> plantIds = new Set<Id>();
        for (Plant_Purchase__c purchase : oldPurchases) {
            if (purchase.Plant__c != null) {
                plantIds.add(purchase.Plant__c);
            }
        }
        if (plantIds.isEmpty()) {
            return;
        }

        Map<Id, Plant__c> plantsById = new Map<Id, Plant__c>(
            [SELECT Id, Name, Stock_Remaining__c FROM Plant__c WHERE Id IN :plantIds WITH SYSTEM_MODE]
        );

        // Running stock per plant as each purchase in the batch is removed.
        Map<Id, Decimal> stockByPlant = new Map<Id, Decimal>();
        for (Plant__c plant : plantsById.values()) {
            stockByPlant.put(plant.Id, nz(plant.Stock_Remaining__c));
        }

        for (Plant_Purchase__c purchase : oldPurchases) {
            Plant__c plant = plantsById.get(purchase.Plant__c);
            if (plant == null) {
                continue;
            }
            Decimal stockNow = stockByPlant.get(plant.Id);
            Decimal stockAfter = stockNow - nz(purchase.Quantity_Purchased__c);
            if (stockAfter < 0) {
                purchase.addError(
                    'Cannot delete ' + purchase.Name + ': ' + plant.Name + ' has only ' +
                    stockNow.format() + ' units in stock, so removing ' +
                    nz(purchase.Quantity_Purchased__c).format() +
                    ' units would make stock negative.'
                );
            } else {
                stockByPlant.put(plant.Id, stockAfter);
            }
        }
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }
}
