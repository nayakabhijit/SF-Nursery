/**
 * Plant_Purchase__c trigger. All logic lives in PlantPurchaseTriggerHandler.
 */
trigger PlantPurchaseTrigger on Plant_Purchase__c(before delete) {
    switch on Trigger.operationType {
        when BEFORE_DELETE {
            PlantPurchaseTriggerHandler.beforeDelete(Trigger.old);
        }
    }
}
