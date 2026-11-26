/**
 * Plant__c trigger. All logic lives in PlantTriggerHandler.
 */
trigger PlantTrigger on Plant__c(before insert, before update) {
    switch on Trigger.operationType {
        when BEFORE_INSERT {
            PlantTriggerHandler.beforeInsert(Trigger.new);
        }
        when BEFORE_UPDATE {
            PlantTriggerHandler.beforeUpdate(Trigger.new, Trigger.oldMap);
        }
    }
}
